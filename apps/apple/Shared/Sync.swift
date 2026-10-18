import CryptoKit
import Foundation

/// What is shared between your own devices, and how two copies are combined. The same snapshot travels over iCloud (sealed with your sync
/// passphrase, so Apple stores only scrambled bytes) and over Wi-Fi (inside the one-time-code tunnel). Passwords, cookies, history and the
/// page index are never part of it, and neither are private tabs.
enum SyncRules {
    /// Settings that mean the same on every device. Layout, sidebar and toolbar choices are left out on purpose: they belong to each screen.
    static let settingKeys: Set<String> = [
        "search_template", "search_suggestions", "search_shortcuts", "accent", "appearance", "address_display", "dark_pages", "dark_sites", "website_appearance", "site_appearance",
        "site_zoom", "site_styles", "site_notes", "bookmark_tags", "group_colors", "strip_tracking", "app_links", "app_link_sites",
        "blur_private_switcher", "permission_expiry", "homepage", "favorites_order", "site_js_off", "never_sleep_sites", "de_amp", "user_themes", "start_tile", "theme_custom", "block_autoplay", "autoplay_exceptions",
        // Rules and per-site choices (the "site rules" group in sync settings).
        "site_open_rules", "site_delete_rules", "site_user_agents", "containers", "split_templates", "workflows", "fingerprint_noise", "fingerprint_exceptions",
        "block_webrtc", "webrtc_exceptions", "video_ads", "cookie_banners", "video_speeds", "autoplay_exceptions",
        // Newer browsing features: pop-ups, chains, panels, the theme schedule, menus, previews, stacks, address bar sources.
        "block_popups", "popup_allowed_hosts", "youtube_rules_auto", "command_chains", "web_panels", "theme_schedule", "hidden_menu_items", "hover_previews", "hover_delay", "tab_stacks", "address_sources", "tab_tree",
        // What the start page shows.
        "show_favorites", "show_continue", "show_frequent", "show_greeting", "show_recently_closed", "start_background",
    ]

    /// The settings that are rules about particular sites, kept apart so they can be switched on and off on their own.
    static let siteRuleKeys: Set<String> = [
        "site_zoom", "site_styles", "site_notes", "site_appearance", "permission_expiry", "site_js_off", "never_sleep_sites", "site_open_rules", "site_delete_rules",
        "site_user_agents", "containers", "split_templates", "workflows", "fingerprint_noise", "fingerprint_exceptions", "block_webrtc", "webrtc_exceptions", "video_ads",
        "app_link_sites", "popup_allowed_hosts",
    ]

    static func category(forSetting key: String) -> SyncCategory { siteRuleKeys.contains(key) ? .siteRules : .settings }
    static let maxTabs = 100
    static let maxBookmarks = 3_000
    /// iCloud's key-value store holds 1 MB in all; a snapshot stays well under it.
    static let maxSealedBytes = 600 * 1024

    /// Combines another device's snapshot into this one. Bookmarks are added, never removed (so nothing is lost by syncing); settings follow
    /// the newer snapshot, and only if the person asked for settings to sync. Returns what changed.
    struct Outcome: Equatable { var bookmarksAdded = 0; var bookmarksRemoved = 0; var bookmarksChanged = 0; var settingsApplied = 0; var workspacesChanged = 0; var sessionsChanged = 0; var loginsChanged = 0; var historyChanged = 0; var tabsReceived = 0; var tabs = 0 }

    static func bookmarksToAdd(remote: [BackupPayload.Bookmark], existing: Set<String>) -> [BackupPayload.Bookmark] {
        var seen = existing
        var out: [BackupPayload.Bookmark] = []
        for b in remote.prefix(maxBookmarks) {
            guard ["http", "https"].contains(URL(string: b.url)?.scheme?.lowercased() ?? ""), seen.insert(b.url).inserted else { continue }
            out.append(b)
        }
        return out
    }

    static func acceptedSettings(_ remote: [String: String]) -> [String: String] { remote.filter { settingKeys.contains($0.key) } }

    static func cleanTabs(_ tabs: [BackupPayload.Tab]) -> [BackupPayload.Tab] {
        Array(tabs.filter { ["http", "https"].contains(URL(string: $0.url)?.scheme?.lowercased() ?? "") }.prefix(maxTabs))
    }

    /// Makes a snapshot fit: first the tabs and the extension list go, then the oldest tombstones (a deletion may then be forgotten and an item could come back),
    /// then the oldest bookmarks of a snapshot without merge state; nothing else is cut.
    static func sealedFitting(_ snapshot: BackupPayload, passphrase: String, iterations: UInt32 = BackupFile.defaultIterations) throws -> Data {
        var working = snapshot
        var sealed = try BackupFile.seal(working, passphrase: passphrase, iterations: iterations)
        while sealed.count > maxSealedBytes {
            if let t = working.tabs, !t.isEmpty { working.tabs = Array(t.prefix(t.count / 2)) }
            else if working.extensions != nil { working.extensions = nil }
            else if var state = working.state, state.history.count > 40 { state.history = SyncRules.newestHistory(state.history, keep: state.history.count / 2); working.state = state }
            else if var state = working.state, SyncRules.dropOldestTombstones(&state) { working.state = state }
            else if working.state == nil, working.bookmarks.count > 50 { working.bookmarks = Array(working.bookmarks.prefix(working.bookmarks.count * 3 / 4)) }
            else { break }
            sealed = try BackupFile.seal(working, passphrase: passphrase, iterations: iterations)
        }
        return sealed
    }

    /// The most recently visited pages, and any deletions, of a history ledger.
    static func newestHistory(_ cells: [String: SyncCell<SyncVisit>], keep: Int) -> [String: SyncCell<SyncVisit>] {
        let live = cells.filter { $0.value.value != nil }.sorted { ($0.value.value?.last ?? 0) > ($1.value.value?.last ?? 0) }.prefix(keep)
        var out = cells.filter { $0.value.value == nil }
        for (k, v) in live { out[k] = v }
        return out
    }

    /// Drops the older half of the tombstones; false when there are none left to drop.
    static func dropOldestTombstones(_ state: inout SyncState) -> Bool {
        var stamps: [Double] = []
        for c in state.bookmarks.values where c.value == nil { stamps.append(c.stamp.time) }
        for c in state.settings.values where c.value == nil { stamps.append(c.stamp.time) }
        for c in state.workspaces.values where c.value == nil { stamps.append(c.stamp.time) }
        for c in state.logins.values where c.value == nil { stamps.append(c.stamp.time) }
        for c in state.sessions.values where c.value == nil { stamps.append(c.stamp.time) }
        for c in state.history.values where c.value == nil { stamps.append(c.stamp.time) }
        guard !stamps.isEmpty else { return false }
        let cut = stamps.sorted()[stamps.count / 2]
        state.bookmarks = state.bookmarks.filter { $0.value.value != nil || $0.value.stamp.time > cut }
        state.settings = state.settings.filter { $0.value.value != nil || $0.value.stamp.time > cut }
        state.workspaces = state.workspaces.filter { $0.value.value != nil || $0.value.stamp.time > cut }
        state.logins = state.logins.filter { $0.value.value != nil || $0.value.stamp.time > cut }
        state.sessions = state.sessions.filter { $0.value.value != nil || $0.value.stamp.time > cut }
        state.history = state.history.filter { $0.value.value != nil || $0.value.stamp.time > cut }
        return true
    }
}

struct RemoteTabs: Codable, Equatable, Identifiable {
    var device: String
    var date: Date
    var tabs: [BackupPayload.Tab]
    var id: String { device }
}

enum SyncKeys {
    static let service = "com.browsersetu.sync"
    /// The passphrase belongs to one profile: two profiles never share one by accident.
    private static func account(_ profile: String) -> String { "passphrase|" + profile }

    static func passphrase(profile: String) -> String? {
        let own = SecretStore.get(service: service, account: account(profile)).flatMap { String(data: $0, encoding: .utf8) }
        if own != nil || profile != "default" { return own }
        // The one passphrase older versions kept belongs to the default profile only.
        return SecretStore.get(service: service, account: "passphrase").flatMap { String(data: $0, encoding: .utf8) }
    }
    @discardableResult static func setPassphrase(_ text: String, profile: String) -> Bool { SecretStore.set(Data(text.utf8), service: service, account: account(profile)) }
    static func clearPassphrase(profile: String) {
        _ = SecretStore.delete(service: service, account: account(profile))
        if profile == "default" { _ = SecretStore.delete(service: service, account: "passphrase") }
    }

    /// A short, stable name for a sync group, used in the iCloud key so only devices in the same group see each other's snapshots.
    static func groupTag(_ group: String) -> String {
        SHA256.hash(data: Data(("browser-setu-sync-group|" + group.lowercased()).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// iCloud's small key-value store. Each device writes its own sealed snapshot under its own key and reads the others, so two devices never
/// overwrite each other. There is no server of ours, and without the passphrase what is stored cannot be read.
@MainActor
final class CloudSync {
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    static var available: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// iCloud's key-value store holds 1 MB in all, for every group and device together; staying under this keeps writes from being refused.
    static let storeBudget = 900 * 1024
    private(set) var group: String

    init(group: String) { self.group = group }

    private var prefix: String { "bs.sync.v2." + SyncKeys.groupTag(group) + "." }
    private func key(_ deviceID: String) -> String { prefix + deviceID }

    /// Everything held under the sync names, in every group: what the 1 MB limit counts.
    var bytesInUse: Int { store.dictionaryRepresentation.filter { $0.key.hasPrefix("bs.sync.") }.reduce(0) { $0 + (($1.value as? Data)?.count ?? 0) } }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        store.synchronize()
    }

    func stop() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }

    /// False when the snapshot does not fit: it is too big on its own, or this would push the whole store past its limit.
    @discardableResult
    func push(_ sealed: Data, deviceID: String) -> Bool {
        guard sealed.count <= SyncRules.maxSealedBytes + 4096 else { return false }
        let replacing = (store.data(forKey: key(deviceID))?.count ?? 0)
        guard bytesInUse - replacing + sealed.count <= Self.storeBudget else { return false }
        store.set(sealed, forKey: key(deviceID))
        store.synchronize()
        return true
    }

    /// The sealed snapshots of the other devices in this group, with each device's id.
    func others(except deviceID: String) -> [(deviceID: String, data: Data)] {
        store.dictionaryRepresentation.compactMap { name, value in
            guard name.hasPrefix(prefix), name != key(deviceID), let data = value as? Data else { return nil }
            return (String(name.dropFirst(prefix.count)), data)
        }
    }

    func forgetThisDevice(deviceID: String) { store.removeObject(forKey: key(deviceID)); store.synchronize() }

    /// The devices in this group that have written a snapshot, by their ids.
    func deviceIDs() -> [String] {
        store.dictionaryRepresentation.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    /// Removes another device's snapshot: it can no longer be read by the others, and does nothing until that device writes again.
    func revoke(deviceID: String) { store.removeObject(forKey: key(deviceID)); store.synchronize() }
}


/// A device seen in this sync group. Nothing from a device is taken in until the user approves it, and a blocked device is ignored for good.
struct SyncDevice: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case pending, approved, blocked }
    var id: String
    var name: String
    var status: Status
    var lastSeen: Date
}

/// A setting that differs between this device and another, waiting for the user's choice.
struct SyncConflict: Equatable, Identifiable {
    var key: String
    var mine: String
    var theirs: String
    var device: String
    /// Where the other value came from, kept so choosing it makes it win everywhere.
    var theirsStamp: SyncStamp? = nil
    var id: String { key }
}
