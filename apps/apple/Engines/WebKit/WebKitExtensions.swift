import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

/// Runs web extensions on WebKit's own extension support (macOS 15.4, iOS 18.4). Extensions are installed from an
/// unpacked folder, copied into the app's storage, and get only the permissions the user approved. They do not run
/// in private tabs, and nothing here contacts a store or a server.
@available(macOS 15.4, iOS 18.4, *)
@MainActor
final class WebKitExtensionManager: NSObject, ExtensionBackend, WKWebExtensionControllerDelegate {
    struct Record: Codable, Equatable {
        var id: String
        var enabled: Bool
        var permissions: [String]
        var hosts: [String]
        /// The Chrome Web Store id, for extensions added from the store. It is what a helper program is checked against.
        var chromeID: String?
        /// True only after the package's signature was checked against that id. Never set today.
        var chromeIDVerified: Bool?
        /// Permissions the user turned off after installing: "api:<name>" or "site:<pattern>".
        var revoked: [String]?
        /// Website patterns the person added themselves, allowed or blocked ("site:" entries in `revoked` mean blocked).
        var customSites: [String]?
        /// The last changes the user made to its permissions, newest last, in words.
        var history: [String]?
    }

    /// Helper programs running for open extension connections (direct-download build only).
    var nativeSessions: [AnyObject] = []
    private var iconCache: [String: Data?] = [:]
    private var publishScheduled = false

    static let maxBytes = ExtensionPackage.maxUnpacked

    let controller: WKWebExtensionController
    private let center: ExtensionCenter
    private weak var host: ExtensionHost?
    let directory: URL
    var records: [Record] = []
    var contexts: [String: WKWebExtensionContext] = [:]
    private var pending: Pending?
    private var tabAdapters: [UInt64: ExtensionTabAdapter] = [:]
    fileprivate lazy var windowAdapter = ExtensionWindowAdapter(manager: self)
    #if os(macOS)
    private var popover: NSPopover?
    #endif

    private var recordsURL: URL { directory.appendingPathComponent("extensions.json") }

    init(profile: String, directory: URL, center: ExtensionCenter, host: ExtensionHost?) {
        self.directory = directory
        self.center = center
        self.host = host
        controller = WKWebExtensionController(configuration: WKWebExtensionController.Configuration(identifier: ProfileIdentity.dataStoreID(for: profile)))
        super.init()
        controller.delegate = self
    }

    // MARK: Start

    func start() async {
        ExtensionPackage.purgeStale()
        try? FileManager.default.removeItem(at: stagingRoot)           // copies made for approvals that were never finished
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        records = ((try? Data(contentsOf: recordsURL)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) }) ?? []
        for record in records {
            let folder = directory.appendingPathComponent(record.id, isDirectory: true)
            guard let loaded = try? await WKWebExtension(resourceBaseURL: folder) else { continue }
            let context = makeContext(loaded, record: record)
            contexts[record.id] = context
            if record.enabled { try? controller.load(context) }
        }
        controller.didOpenWindow(windowAdapter)
        controller.didFocusWindow(windowAdapter)
        for tab in host?.extensionTabs ?? [] { controller.didOpenTab(adapter(for: tab)) }
        publish()
    }

    func makeContext(_ loaded: WKWebExtension, record: Record) -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: loaded)
        context.uniqueIdentifier = record.id
        let revoked = Set(record.revoked ?? [])
        for permission in record.permissions {
            context.setPermissionStatus(revoked.contains("api:" + permission) ? .deniedExplicitly : .grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        for pattern in record.hosts {
            if let match = try? WKWebExtension.MatchPattern(string: pattern) {
                context.setPermissionStatus(revoked.contains("site:" + pattern) ? .deniedExplicitly : .grantedExplicitly, for: match)
            }
        }
        return context
    }

    func saveRecords() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: recordsURL, options: .atomic) }
    }

    // MARK: Install, remove, enable

    /// What was inspected and shown to the user: a private copy of the extension (so nobody can change it while the sheet is open), the SHA-256 of that
    /// copy, and the approval token the sheet carries.
    private struct Pending {
        var staged: URL
        var info: ExtensionInfo
        var digest: String
        var token: String
        var chromeID: String?
        var permissions: Set<String>
        var sites: Set<String>
    }

    private var stagingRoot: URL { directory.appendingPathComponent(".staging", isDirectory: true) }

    private func discardPending() {
        if let staged = pending?.staged { try? FileManager.default.removeItem(at: staged) }
        pending = nil
    }

    func inspect(folder: URL, chromeID: String? = nil, replacing: String? = nil) async throws -> ExtensionInfo {
        // Only the extension inspected most recently can be installed: a failed look never leaves an older approval behind.
        discardPending()
        var handedOver = false
        defer { if !handedOver { ExtensionPackage.discardUnpacked(folder) } }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard Self.size(of: folder) <= Self.maxBytes else { throw ExtensionError.tooLarge }
        // Review a private copy, not the folder the user pointed at: whoever else can write to that folder cannot change what is reviewed.
        let token = UUID().uuidString
        let staged = stagingRoot.appendingPathComponent(token, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder, to: staged)
        } catch { throw ExtensionError.copyFailed }
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: staged) } }
        guard let digest = await Task.detached(priority: .userInitiated, operation: { ExtensionPackage.digest(of: staged) }).value else { throw ExtensionError.copyFailed }
        let loaded: WKWebExtension
        do { loaded = try await WKWebExtension(resourceBaseURL: staged) }
        catch { throw ExtensionError.notAnExtension(error.localizedDescription) }
        var info = describe(loaded, id: "pending", enabled: false, fallbackName: folder.lastPathComponent)
        info.compatibility = ExtensionCompatibility.notes(inExtensionAt: staged)
        info.manifestVersion = ExtensionCompatibility.manifestVersion(inExtensionAt: staged)
        info.approvalToken = token
        let permissions = Set(loaded.requestedPermissions.map(\.rawValue)), sites = Set(loaded.requestedPermissionMatchPatterns.map(\.string))
        if let replacing, let old = records.first(where: { $0.id == replacing }) {
            let added = permissions.subtracting(old.permissions).map { Self.words(for: $0) } + sites.subtracting(old.hosts).map { $0 == "<all_urls>" ? "Read and change all websites" : "Read and change \($0)" }
            info.addedPermissions = added.sorted()
        }
        pending = Pending(staged: staged, info: info, digest: digest, token: token, chromeID: chromeID, permissions: permissions, sites: sites)
        keep = true
        handedOver = true
        ExtensionPackage.discardUnpacked(folder)
        return info
    }

    func installPending() async throws { try await installPending(replacing: nil, token: nil) }

    /// Installs exactly what was reviewed. With `replacing`, it goes over that extension (an update): same identity, its saved data, whether it was on, and
    /// every permission the user had turned off carry over; permissions it did not have before come in as the user just approved them. If the copy on disk no
    /// longer matches what was reviewed, nothing is installed.
    func installPending(replacing existing: String?, token: String?) async throws {
        guard let pending else { throw ExtensionError.nothingToInstall }
        if let token, token != pending.token { throw ExtensionError.approvalExpired }
        let id = existing ?? UUID().uuidString
        let target = directory.appendingPathComponent(id, isDirectory: true)
        let backup = directory.appendingPathComponent(id + ".old", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The private copy is checked against its hash once more before anything is installed from it.
        guard await Task.detached(priority: .userInitiated, operation: { ExtensionPackage.digest(of: pending.staged) }).value == pending.digest else {
            discardPending(); throw ExtensionError.changedSinceReview
        }
        let old = records.first { $0.id == id }
        let wasEnabled = old?.enabled ?? true
        var movedAside = false
        if existing != nil, FileManager.default.fileExists(atPath: target.path) {
            if let context = contexts[id] { try? controller.unload(context) }
            try? FileManager.default.removeItem(at: backup)
            do { try FileManager.default.moveItem(at: target, to: backup); movedAside = true } catch { throw ExtensionError.copyFailed }
        }
        func undo() {
            try? FileManager.default.removeItem(at: target)
            guard movedAside else { return }
            try? FileManager.default.moveItem(at: backup, to: target)
            if wasEnabled, let context = contexts[id] { try? controller.load(context) }
        }
        do { try FileManager.default.copyItem(at: pending.staged, to: target) } catch { undo(); throw ExtensionError.copyFailed }
        // And what landed in the installed place must be the same bytes, and ask for the same things, as what was reviewed.
        guard await Task.detached(priority: .userInitiated, operation: { ExtensionPackage.digest(of: target) }).value == pending.digest else { undo(); discardPending(); throw ExtensionError.changedSinceReview }
        let loaded: WKWebExtension
        do { loaded = try await WKWebExtension(resourceBaseURL: target) }
        catch { undo(); throw ExtensionError.notAnExtension(error.localizedDescription) }
        guard Set(loaded.requestedPermissions.map(\.rawValue)) == pending.permissions, Set(loaded.requestedPermissionMatchPatterns.map(\.string)) == pending.sites else {
            undo(); discardPending(); throw ExtensionError.changedSinceReview
        }
        // What the user turned off stays off for anything that is still asked for; the rest is what they just approved.
        let permissions = loaded.requestedPermissions.map(\.rawValue).sorted()
        let hosts = loaded.requestedPermissionMatchPatterns.map(\.string).sorted()
        let stillAsked = Set(permissions.map { "api:" + $0 } + hosts.map { "site:" + $0 })
        let kept = Set(old?.revoked ?? []).intersection(stillAsked)
        var record = Record(id: id, enabled: wasEnabled, permissions: permissions, hosts: hosts,
                            chromeID: pending.chromeID,                          // never inherited: an update from elsewhere does not keep a store identity
                            revoked: kept.isEmpty ? nil : kept.sorted(), history: old?.history)
        if existing != nil {
            let version = loaded.displayVersion ?? loaded.version ?? ""
            let added = pending.info.addedPermissions
            var list = record.history ?? []
            list.append(RelativeDateTimeFormatter.shortStamp() + " Updated\(version.isEmpty ? "" : " to " + version)" + (added.isEmpty ? "" : "; new: " + added.joined(separator: ", ")))
            record.history = Array(list.suffix(20))
        }
        let context = makeContext(loaded, record: record)
        if wasEnabled { do { try controller.load(context) } catch { undo(); throw ExtensionError.notAnExtension(error.localizedDescription) } }
        contexts[id] = context
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record } else { records.append(record) }
        // The version it replaced stays beside it, so one tap can go back.
        let previous = directory.appendingPathComponent(id + ".prev", isDirectory: true)
        try? FileManager.default.removeItem(at: previous)
        if movedAside { try? FileManager.default.moveItem(at: backup, to: previous) } else { try? FileManager.default.removeItem(at: backup) }
        saveRecords()
        discardPending()
        publish()
    }

    /// Opens the extension's own settings page in a tab.
    func openOptions(id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        _ = host?.extensionOpenTab(url: url)
    }

    func remove(id: String) async {
        if let context = contexts[id] { try? controller.unload(context) }
        contexts[id] = nil
        let types = WKWebExtensionController.allExtensionDataTypes
        let mine = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
        if !mine.isEmpty { await controller.removeData(ofTypes: types, from: mine) }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".prev", isDirectory: true))
        records.removeAll { $0.id == id }
        saveRecords()
        publish()
    }

    func setEnabled(id: String, enabled: Bool) async {
        guard let index = records.firstIndex(where: { $0.id == id }), let context = contexts[id] else { return }
        if enabled { try? controller.load(context) } else { try? controller.unload(context) }
        records[index].enabled = enabled
        saveRecords()
        publish()
    }

    private var frontTab: ExtensionTabAdapter? { host?.extensionActiveTab.map { adapter(for: $0) } }

    func perform(actionFor id: String) { contexts[id]?.performAction(for: frontTab) }

    func permissionRows(id: String) -> [ExtensionPermissionRow] {
        guard let record = records.first(where: { $0.id == id }) else { return [] }
        let revoked = Set(record.revoked ?? [])
        let live = contexts[id]
        let apis = Set(record.permissions).union(live?.grantedPermissions.keys.map(\.rawValue) ?? [])
        let sites = Set(record.hosts).union(live?.grantedPermissionMatchPatterns.keys.map(\.string) ?? [])
        let apiRows = apis.sorted().map { ExtensionPermissionRow(key: $0, title: Self.words(for: $0), isSite: false, granted: !revoked.contains("api:" + $0)) }
        let custom = Set(record.customSites ?? [])
        let siteRows = sites.sorted().map { ExtensionPermissionRow(key: $0, title: $0 == "<all_urls>" ? "All websites" : (custom.contains($0) ? ExtensionSitePattern.host(of: $0) : $0), isSite: true, granted: !revoked.contains("site:" + $0), custom: custom.contains($0)) }
        return apiRows + siteRows
    }

    /// Takes a permission away (or gives it back) at once, and keeps the choice across launches.
    func setPermission(id: String, key: String, isSite: Bool, granted: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let tag = (isSite ? "site:" : "api:") + key
        var revoked = Set(records[index].revoked ?? [])
        if granted { revoked.remove(tag) } else { revoked.insert(tag) }
        records[index].revoked = revoked.sorted()
        // Kept in the record, so a permission granted while the extension was running still shows up here after it is turned off.
        if isSite { if !records[index].hosts.contains(key) { records[index].hosts.append(key) } }
        else if !records[index].permissions.contains(key) { records[index].permissions.append(key) }
        let status: WKWebExtensionContext.PermissionStatus = granted ? .grantedExplicitly : .deniedExplicitly
        if isSite { if let match = try? WKWebExtension.MatchPattern(string: key) { contexts[id]?.setPermissionStatus(status, for: match) } }
        else { contexts[id]?.setPermissionStatus(status, for: WKWebExtension.Permission(rawValue: key)) }
        note("\(granted ? "Allowed" : "Turned off"): \(isSite ? (key == "<all_urls>" ? "all websites" : key) : Self.words(for: key))", at: index)
        saveRecords()
    }

    /// A rule for one website: allowed (it may read and change that site even when its own request was narrower) or blocked (it may not, even if it asked for every site).
    func addSiteRule(id: String, host: String, allow: Bool) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }), let pattern = ExtensionSitePattern.pattern(forHost: host),
              (records[index].customSites ?? []).count < 100 else { return false }
        var list = records[index].customSites ?? []
        if !list.contains(pattern) { list.append(pattern) }
        records[index].customSites = list
        setPermission(id: id, key: pattern, isSite: true, granted: allow)
        return true
    }

    func removeSiteRule(id: String, key: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), (records[index].customSites ?? []).contains(key) else { return }
        records[index].customSites = records[index].customSites?.filter { $0 != key }
        records[index].hosts.removeAll { $0 == key }
        records[index].revoked = records[index].revoked?.filter { $0 != "site:" + key }
        if let match = try? WKWebExtension.MatchPattern(string: key) { contexts[id]?.setPermissionStatus(.unknown, for: match) }
        note("Removed the rule for \(ExtensionSitePattern.host(of: key))", at: index)
        saveRecords()
    }

    private func note(_ text: String, at index: Int) {
        var list = records[index].history ?? []
        list.append(RelativeDateTimeFormatter.shortStamp() + " " + text)
        records[index].history = Array(list.suffix(20))
    }

    func permissionHistory(id: String) -> [String] { (records.first { $0.id == id }?.history ?? []).reversed() }

    private static let broadPatterns: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"]

    func siteAccess(id: String) -> ExtensionSiteAccess {
        guard let record = records.first(where: { $0.id == id }) else { return .specific }
        let revoked = Set(record.revoked ?? [])
        let granted = record.hosts.filter { !revoked.contains("site:" + $0) }
        if granted.contains(where: { Self.broadPatterns.contains($0) }) { return .all }
        return granted.isEmpty ? .onClick : .specific
    }

    /// All: every site it asked for. Specific: the named sites only, none of the broad patterns. On click: no standing site access at all.
    func setSiteAccess(id: String, mode: ExtensionSiteAccess) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        for pattern in record.hosts {
            let broad = Self.broadPatterns.contains(pattern)
            let granted: Bool
            switch mode {
            case .all: granted = true
            case .specific: granted = !broad
            case .onClick: granted = false
            }
            setPermission(id: id, key: pattern, isSite: true, granted: granted)
        }
    }

    func owns(url: URL) -> Bool { controller.extensionContext(for: url) != nil }

    // MARK: What the user sees

    private func describe(_ loaded: WKWebExtension, id: String, enabled: Bool, fallbackName: String = "Extension") -> ExtensionInfo {
        ExtensionInfo(
            id: id,
            name: loaded.displayName ?? fallbackName,
            version: loaded.displayVersion ?? loaded.version ?? "",
            enabled: enabled,
            permissions: loaded.requestedPermissions.map { Self.words(for: $0.rawValue) }.sorted(),
            sites: loaded.requestedPermissionMatchPatterns.map(\.string).sorted(),
            problems: loaded.errors.map(\.localizedDescription),
            hasOptions: loaded.hasOptionsPage)
    }

    func publish() {
        iconCache.removeAll()
        let infos = records.compactMap { record -> ExtensionInfo? in
            guard let context = contexts[record.id] else { return nil }
            return describe(context.webExtension, id: record.id, enabled: record.enabled)
        }
        center.publish(extensions: infos, actions: actionItems())
    }

    /// The toolbar buttons as they are for the tab in front: an extension may switch its button on or off per page, so this is asked again whenever the
    /// tab or its page changes. (The default state, with no tab, can show a button as off that works fine on the page in front.)
    private func actionItems() -> [ExtensionActionItem] {
        let tab = frontTab
        return records.filter(\.enabled).compactMap { record -> ExtensionActionItem? in
            guard let context = contexts[record.id], context.isLoaded, let action = context.action(for: tab) else { return nil }
            // Turning the icon into PNG data is the slow part, and it hardly ever changes: it is made once per extension and button label, not on every tab change.
            let key = record.id + "|" + action.label
            let icon: Data?
            if let cached = iconCache[key] { icon = cached } else { icon = Self.png(action.icon(for: CGSize(width: 32, height: 32))); iconCache[key] = icon }
            return ExtensionActionItem(id: record.id, label: action.label, badge: action.badgeText, enabled: action.isEnabled, icon: icon)
        }
    }

    /// Asked for often (every tab and page change), so a burst becomes one pass shortly after.
    private func publishActions() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            publishScheduled = false
            center.publish(extensions: center.extensions, actions: actionItems())
        }
    }

    static func words(for permission: String) -> String {
        let names: [String: String] = [
            "activeTab": "Use the page you are on when you click its button",
            "alarms": "Run tasks on a schedule",
            "bookmarks": "Read and change your bookmarks",
            "clipboardRead": "Read what you copied",
            "clipboardWrite": "Put text on your clipboard",
            "contextMenus": "Add items to the right-click menu",
            "cookies": "Read and change cookies",
            "declarativeNetRequest": "Block or change web requests",
            "declarativeNetRequestWithHostAccess": "Block or change web requests on its sites",
            "downloads": "Manage downloads",
            "history": "Read your browsing history",
            "menus": "Add items to menus",
            "nativeMessaging": "Talk to Apple's own helper apps on this Mac (direct-download build only)",
            "notifications": "Show notifications",
            "scripting": "Run scripts in web pages",
            "storage": "Save its own settings",
            "tabs": "See the titles and addresses of your tabs",
            "unlimitedStorage": "Store large amounts of its own data",
            "webNavigation": "See how pages load",
            "webRequest": "Watch web requests",
        ]
        return names[permission] ?? permission
    }

    private static func png(_ image: PlatformImage?) -> Data? {
        guard let image else { return nil }
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }

    private static func size(of folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
            if total > maxBytes { break }
        }
        return total
    }

    // MARK: Tabs the extensions can see

    fileprivate func adapter(for tab: TabController) -> ExtensionTabAdapter {
        if let existing = tabAdapters[tab.id] { return existing }
        let made = ExtensionTabAdapter(tab: tab, manager: self)
        tabAdapters[tab.id] = made
        return made
    }

    fileprivate var visibleAdapters: [ExtensionTabAdapter] { (host?.extensionTabs ?? []).map { adapter(for: $0) } }
    fileprivate var activeAdapter: ExtensionTabAdapter? { host?.extensionActiveTab.map { adapter(for: $0) } }
    fileprivate var hostRef: ExtensionHost? { host }

    func tabOpened(_ tab: TabController) { controller.didOpenTab(adapter(for: tab)) }

    func tabClosed(_ tab: TabController) {
        guard let existing = tabAdapters[tab.id] else { return }
        controller.didCloseTab(existing, windowIsClosing: false)
        tabAdapters[tab.id] = nil
    }

    func tabActivated(_ tab: TabController, previous: TabController?) {
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous.map { adapter(for: $0) })
        publishActions()
    }

    func tabChanged(_ tab: TabController) {
        guard let existing = tabAdapters[tab.id] else { return }
        controller.didChangeTabProperties([.URL, .title, .loading], for: existing)
        if tab.id == host?.extensionActiveTab?.id { publishActions() }
    }

    // MARK: Delegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [windowAdapter]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let host else { return nil }
        let tab = host.extensionOpenTab(url: configuration.url)
        return adapter(for: tab)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let host, let url = extensionContext.optionsPageURL else { return }
        _ = host.extensionOpenTab(url: url)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let list = permissions.map { Self.words(for: $0.rawValue) }.sorted().joined(separator: "\n• ")
        let allowed = await host?.extensionAsk(title: "Allow “\(extensionContext.webExtension.displayName ?? "this extension")” to do more?",
                                               message: "It is asking to:\n• \(list)", allow: "Allow") ?? false
        if allowed { remember(context: extensionContext, apis: permissions.map(\.rawValue), sites: [], how: "Allowed when asked") }
        return (allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let hosts = Set(urls.compactMap(\.host)).sorted().joined(separator: ", ")
        let allowed = await host?.extensionAsk(title: "Let “\(extensionContext.webExtension.displayName ?? "this extension")” use this site?",
                                               message: "It wants to read and change data on \(hosts).", allow: "Allow") ?? false
        if allowed { remember(context: extensionContext, apis: [], sites: Set(urls.compactMap { url in url.host.map { "\(url.scheme ?? "https")://\($0)/*" } }).sorted(), how: "Allowed when asked") }
        return (allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let sites = matchPatterns.map(\.string).sorted().joined(separator: "\n• ")
        let allowed = await host?.extensionAsk(title: "Let “\(extensionContext.webExtension.displayName ?? "this extension")” use more sites?",
                                               message: "It wants to read and change data on:\n• \(sites)", allow: "Allow") ?? false
        if allowed { remember(context: extensionContext, apis: [], sites: matchPatterns.map(\.string), how: "Allowed when asked") }
        return (allowed ? matchPatterns : [], nil)
    }

    /// A permission the user allowed while the extension was running is kept like one granted at install: it is saved, listed on the permissions screen,
    /// written into the change history, and granted again after a restart.
    private func remember(context: WKWebExtensionContext, apis: [String], sites: [String], how: String) {
        guard let id = contexts.first(where: { $0.value === context })?.key, let index = records.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        for key in apis where !records[index].permissions.contains(key) { records[index].permissions.append(key); note("\(how): \(Self.words(for: key))", at: index); changed = true }
        for key in sites where !records[index].hosts.contains(key) { records[index].hosts.append(key); note("\(how): \(key)", at: index); changed = true }
        if changed { saveRecords() }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        publish()
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        #if os(macOS)
        guard let content = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { throw ExtensionError.unsupported }
        popover?.close()
        // WebKit's own popover for the action: it sizes itself to the popup page, as the extension asked, and closes when the extension does.
        let shown: NSPopover
        if let provided = action.popupPopover {
            shown = provided
        } else if let popupView = action.popupWebView {
            let size = NSSize(width: 360, height: 480)
            popupView.frame = NSRect(origin: .zero, size: size)
            let controllerView = NSViewController()
            controllerView.view = popupView
            shown = NSPopover()
            shown.contentSize = size
            shown.contentViewController = controllerView
        } else {
            throw ExtensionError.unsupported
        }
        shown.behavior = .transient
        // Attached to the button that was clicked, the way Chrome's popups hang from their icons. With no button known it falls back to the top right.
        let target: NSRect
        let fresh = Date().timeIntervalSince(center.anchorDate) < 2
        if fresh, let click = center.clickPoint {
            let p = content.convert(click, from: nil)
            target = NSRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)
        } else if fresh, let a = center.anchor {
            target = NSRect(x: a.minX, y: content.isFlipped ? a.minY : content.bounds.height - a.maxY, width: a.width, height: a.height)
        } else {
            target = NSRect(x: content.bounds.maxX - 90, y: content.bounds.maxY - 6, width: 1, height: 1)
        }
        // Below a button near the top, above one near the bottom (the sidebar's footer); AppKit flips it if there is no room.
        // `target.midY` grows downward in a flipped view and upward in an unflipped one; "low" means the lower 40% of the window either way.
        let fromTop = content.isFlipped ? target.midY : content.bounds.height - target.midY
        let low = fromTop > content.bounds.height * 0.6
        // Visually below the button (toward the page) unless the button is low in the window, then above it.
        let below: NSRectEdge = content.isFlipped ? .maxY : .minY
        let above: NSRectEdge = content.isFlipped ? .minY : .maxY
        shown.show(relativeTo: target, of: content, preferredEdge: low ? above : below)
        center.anchor = nil
        center.clickPoint = nil
        popover = shown
        #else
        // On the iPhone WebKit gives a view controller for the popup; it is shown as a sheet that the extension itself can close.
        guard let popup = action.popupViewController else { throw ExtensionError.unsupported }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { throw ExtensionError.unsupported }
        while let next = top.presentedViewController { top = next }
        popup.title = context.webExtension.displayName
        let holder = UINavigationController(rootViewController: popup)
        popup.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak holder] _ in holder?.dismiss(animated: true) })
        holder.modalPresentationStyle = .pageSheet
        if let sheet = holder.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        top.present(holder, animated: true)
        #endif
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

// MARK: - The browser's tabs and window, as extensions see them

@available(macOS 15.4, iOS 18.4, *)
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let tab: TabController
    private weak var manager: WebKitExtensionManager?

    init(tab: TabController, manager: WebKitExtensionManager) {
        self.tab = tab
        self.manager = manager
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { manager?.windowAdapter }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { manager?.visibleAdapters.firstIndex { $0 === self } ?? 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab.engine.hostView as? WKWebView }
    func title(for context: WKWebExtensionContext) -> String? { tab.title }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab.pinned }
    func url(for context: WKWebExtensionContext) -> URL? { tab.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !tab.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { manager?.activeAdapter === self }
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { tab.load(url) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { tab.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { tab.goForward() }
    func activate(for context: WKWebExtensionContext) async throws { manager?.hostRef?.extensionSelect(tab) }
    func close(for context: WKWebExtensionContext) async throws { manager?.hostRef?.extensionClose(tab) }
}

@available(macOS 15.4, iOS 18.4, *)
@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private weak var manager: WebKitExtensionManager?
    init(manager: WebKitExtensionManager) { self.manager = manager }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { manager?.visibleAdapters ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { manager?.activeAdapter }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}


extension RelativeDateTimeFormatter {
    static func shortStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: Date())
    }
}
