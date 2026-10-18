import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The state behind the Workbench: Vim keys, search across everything, workflows, download rules, developer tools, extension tools and the health page.
@MainActor
final class Workbench: ObservableObject {
    weak var model: BrowserModel?

    // Keyboard
    @Published var vimEnabled = false { didSet { save("vim_on", vimEnabled ? "1" : "0") } }
    @Published var keymap = VimKeymap.standard { didSet { save("vim_keymap", keymap.encoded()) } }
    private var machine = VimMachine()

    // Automation
    @Published var workflows: [Workflow] = []
    @Published var workflowHistory: [WorkflowRun] = []
    @Published var startupWorkflow: String?
    @Published var grants = ScriptGrants()
    @Published var schedule: [ScheduledCheck] = []
    @Published var lastWorkflowMessage: String?
    private var scheduler: Task<Void, Never>?

    // Site rules
    @Published var siteRules: [SiteOpenRule] = []

    // Files
    @Published var downloadRules: [DownloadRule] = []
    @Published var duplicates: [DuplicateFiles.Group] = []

    // Developer
    @Published var snapshot: DevSnapshot?
    @Published var scratchOutput = ""
    @Published var inspectable = false
    @Published var openDocumentRequested = false
    @Published var picked: PickedElement?
    @Published var picking = false
    @Published var showSizeHUD = false

    // Extensions
    @Published var extensionProfiles: [String: [String]] = [:]
    @Published var checks: [ExtensionCheck] = []

    init(model: BrowserModel) {
        self.model = model
        func get(_ key: String) -> String? { (try? model.core.getSetting(key: key)) ?? nil }
        vimEnabled = get("vim_on") == "1"
        keymap = get("vim_keymap").map(VimKeymap.decode) ?? .standard
        machine.keymap = keymap
        workflows = BrowserModel.decodeMap(get("workflows"), as: [Workflow].self)["list"] ?? []
        workflowHistory = BrowserModel.decodeMap(get("workflow_history"), as: [WorkflowRun].self)["list"] ?? []
        startupWorkflow = get("startup_workflow").flatMap { $0.isEmpty ? nil : $0 }
        grants = BrowserModel.decodeMap(get("script_grants"), as: ScriptGrants.self)["grants"] ?? ScriptGrants()
        schedule = BrowserModel.decodeMap(get("scheduled_checks"), as: [ScheduledCheck].self)["list"] ?? []
        siteRules = BrowserModel.decodeMap(get("site_open_rules"), as: [SiteOpenRule].self)["list"] ?? []
        downloadRules = BrowserModel.decodeMap(get("download_rules"), as: [DownloadRule].self)["list"] ?? []
        model.downloads.rules = downloadRules
        extensionProfiles = BrowserModel.decodeMap(get("extension_profiles"), as: [String].self)
        startScheduler()
    }

    private func save(_ key: String, _ value: String) { model?.saveSetting(key, value) }
    private func saveMap<T: Encodable>(_ key: String, _ name: String, _ value: T) {
        guard let model else { return }
        model.saveSetting(key, model.encodedMap([name: value]))
    }

    // MARK: Vim

    /// Called for each typed character while no text field has the keyboard. True means the browser used it.
    func handleVimKey(_ key: String) -> Bool {
        guard vimEnabled, let model, model.sheet == nil, !model.paletteVisible else { return false }
        machine.keymap = keymap
        if key == "\u{1B}" { machine.reset(); return false }
        switch machine.feed(key) {
        case .none: return false
        case .waiting: return true
        case .run(let action, let times): perform(action, times: times); return true
        }
    }

    func perform(_ action: VimAction, times: Int = 1) {
        guard let model else { return }
        let tab = model.active
        switch action {
        case .scrollDown: tab?.engine.scrollBy(Double(80 * times))
        case .scrollUp: tab?.engine.scrollBy(Double(-80 * times))
        case .scrollHalfDown: tab?.engine.scrollBy(Double(400 * times))
        case .scrollHalfUp: tab?.engine.scrollBy(Double(-400 * times))
        case .scrollTop: tab?.scrollToEdge(bottom: false)
        case .scrollBottom: tab?.scrollToEdge(bottom: true)
        case .back: for _ in 0..<times { tab?.goBack() }
        case .forward: for _ in 0..<times { tab?.goForward() }
        case .reload: tab?.reload()
        case .newTab: _ = model.newTab()
        case .closeTab: if let id = model.activeID { model.closeTab(id: id) }
        case .reopenTab: model.reopenClosedTab()
        case .nextTab: for _ in 0..<times { model.selectAdjacent(1) }
        case .previousTab: for _ in 0..<times { model.selectAdjacent(-1) }
        case .openSwitcher: model.sheet = .workbench
        case .focusAddress: model.focusAddressBar()
        case .find: model.showFind()
        case .copyURL: if let url = tab?.url { copyToPasteboard(url.absoluteString); model.notice = "Address copied." }
        case .bookmark: model.toggleBookmark()
        case .toggleSidebar: model.sidebarVisible.toggle()
        }
    }

    // MARK: Search across everything

    func search(_ query: String) -> [SearchEntry] {
        guard let model, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var entries: [SearchEntry] = []
        for tab in model.tabs where !tab.isPrivate {
            entries.append(SearchEntry(kind: .tab, title: tab.title, detail: tab.url?.host ?? "", url: tab.url?.absoluteString, key: "\(tab.id)"))
        }
        for b in (try? model.core.listBookmarks(query: "")) ?? [] {
            entries.append(SearchEntry(kind: .bookmark, title: b.title, detail: b.folder, url: b.url, key: b.url))
        }
        let first = UnifiedSearch.terms(query).first ?? query
        for h in (try? model.core.searchHistory(query: first, limit: 80)) ?? [] {
            entries.append(SearchEntry(kind: .history, title: h.title, detail: URL(string: h.url)?.host ?? "", url: h.url, key: h.url))
        }
        for file in model.downloads.completed.prefix(200) {
            entries.append(SearchEntry(kind: .download, title: file.lastPathComponent, detail: file.deletingLastPathComponent().lastPathComponent, url: nil, key: file.path))
        }
        for item in model.readingList {
            entries.append(SearchEntry(kind: .reading, title: item.title, detail: item.site + (item.hasOfflineCopy ? " · offline" : "") + (item.highlights.isEmpty ? "" : " · " + item.highlights.joined(separator: " ")), url: item.url, key: item.id.uuidString))
        }
        for closed in model.closedTabs {
            entries.append(SearchEntry(kind: .closed, title: closed.title, detail: closed.url.host ?? "", url: closed.url.absoluteString, key: closed.url.absoluteString))
        }
        for session in model.savedSessions {
            let sites = session.tabs.map { $0.title }.joined(separator: " · ")
            entries.append(SearchEntry(kind: .session, title: session.name, detail: "\(session.tabs.count) tabs · " + sites, url: nil, key: session.id.uuidString))
        }
        for collection in model.research.collections {
            for item in collection.items {
                entries.append(SearchEntry(kind: .research, title: item.title, detail: collection.name + (item.text.map { " · " + $0 } ?? ""), url: item.url, key: item.id.uuidString))
            }
        }
        for (host, note) in model.siteNotes {
            entries.append(SearchEntry(kind: .note, title: host, detail: note, url: "https://" + host, key: host))
        }
        for item in model.allPaletteItems(full: true) where !item.id.hasPrefix("tab-") && !item.id.hasPrefix("profile-") {
            entries.append(SearchEntry(kind: .command, title: item.title, detail: item.subtitle, url: nil, key: item.id))
        }
        return UnifiedSearch.search(query, in: entries)
    }

    func open(_ entry: SearchEntry) {
        guard let model else { return }
        model.sheet = nil
        switch entry.kind {
        case .tab: if let id = UInt64(entry.key) { model.select(id) }
        case .reading: if let id = UUID(uuidString: entry.key), let item = model.readingList.first(where: { $0.id == id }) { model.openReadingItem(item) }
        case .session: if let id = UUID(uuidString: entry.key), let session = model.savedSessions.first(where: { $0.id == id }) { model.openSession(session) }
        case .bookmark, .history, .closed, .research, .note:
            if let raw = entry.url, let url = URL(string: raw) { _ = model.openTab(url: url, isPrivate: false) }
        case .download:
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.key)])
            #endif
        case .command: model.allPaletteItems(full: true).first { $0.id == entry.key }?.run()
        }
    }

    // MARK: Automation

    /// Commands a workflow or an outside link may run. Anything that deletes or changes settings is left out on purpose.
    static let safeCommands: Set<String> = ["new-tab", "new-private", "reopen", "sidebar", "overview", "bookmarks", "history", "downloads", "restore-layout", "group-by-site", "scratch-tab", "research", "site-privacy", "layout-research", "layout-writing", "layout-media", "layout-minimal"]

    func setWorkflows(_ list: [Workflow]) { workflows = list; saveMap("workflows", "list", list) }

    func addWorkflow(_ workflow: Workflow) -> Bool {
        guard workflow.isValid, workflows.count < 50, !workflows.contains(where: { $0.id == workflow.id }) else { return false }
        setWorkflows(workflows + [workflow]); return true
    }

    /// Runs the steps one after another. Each step is one of a fixed set; none of them runs code.
    func setStartupWorkflow(_ id: String?) { startupWorkflow = id; save("startup_workflow", id ?? "") }

    func run(_ workflow: Workflow, source: String = "by you") {
        guard let model else { return }
        workflowHistory = Array(([WorkflowRun(name: workflow.name, steps: workflow.steps.count, source: source)] + workflowHistory).prefix(50))
        saveMap("workflow_history", "list", workflowHistory)
        Task { @MainActor in
            for step in workflow.steps {
                switch step.kind {
                case .openURL: if let url = URL(string: step.value) { _ = model.openTab(url: url, isPrivate: false) }
                case .search: if let url = model.searchURL(for: step.value) { _ = model.openTab(url: url, isPrivate: false) }
                case .command:
                    if Self.safeCommands.contains(step.value) { model.allPaletteItems(full: true).first { $0.id == step.value }?.run() }
                    else { lastWorkflowMessage = "“\(step.value)” is not a command a workflow may run." }
                case .wait: try? await Task.sleep(for: .seconds(Double(step.value) ?? 1))
                }
            }
            model.notice = "Ran “\(workflow.name)”."
        }
    }

    /// An action from a link or Shortcuts. Anything that opens pages or runs steps is confirmed first, because a web page can fire these links.
    func handle(_ action: URLAction) {
        guard let model else { return }
        Task { @MainActor in
            switch action {
            case .open(let url, let isPrivate): _ = model.openTab(url: url, isPrivate: isPrivate)
            case .search(let text): if let url = model.searchURL(for: text) { _ = model.openTab(url: url, isPrivate: false) }
            case .command(let id):
                guard Self.safeCommands.contains(id) else { model.notice = "That command cannot be run from outside the browser."; return }
                model.allPaletteItems(full: true).first { $0.id == id }?.run()
            case .workflow(let name):
                guard let flow = workflows.first(where: { $0.id == name.lowercased() }) else { model.notice = "There is no workflow called “\(name)”."; return }
                let answer = await Dialogs.choose(title: "Run “\(flow.name)”?", message: "Something outside the browser asked to run these \(flow.steps.count) steps.", buttons: ["Run", "Cancel"])
                if answer == 0 { run(flow) }
            }
        }
    }

    func addSchedule(for tab: TabController, everyMinutes: Int) {
        guard !tab.isPrivate, let url = tab.url, let key = PageMemoryKey.key(for: url), ScheduledCheck.allowedIntervals.contains(everyMinutes), schedule.count < 20 else { return }
        guard model?.watchedPages[key] != nil else { model?.notice = "Watch the page first, then schedule it."; return }
        schedule.removeAll { $0.key == key }
        schedule.append(ScheduledCheck(key: key, url: url.absoluteString, everyMinutes: everyMinutes))
        saveMap("scheduled_checks", "list", schedule)
    }

    func removeSchedule(_ key: String) { schedule.removeAll { $0.key == key }; saveMap("scheduled_checks", "list", schedule) }

    /// While the app is open, a due page is opened in a scratch tab (no sign-in, nothing saved), read, compared and closed. Pages that need a sign-in are not seen as you see them.
    private func startScheduler() {
        scheduler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.runDueChecks()
            }
        }
    }

    func runDueChecks() async {
        guard let model, model.hasStarted else { return }
        for index in schedule.indices where schedule[index].isDue(now: Date()) {
            let item = schedule[index]
            guard let url = URL(string: item.url), let watch = model.watchedPages[item.key] else { continue }
            schedule[index].lastRun = Date().timeIntervalSince1970
            let tab = model.openTab(url: url, isPrivate: false, select: false, scratch: true)
            for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(500)); if !tab.isLoading, tab.url != nil { break } }
            try? await Task.sleep(for: .seconds(2))
            if let text = await tab.engine.pageText() {
                switch WatchCheck.evaluate(watch: watch, newText: text) {
                case .unchanged: break
                case .changed: model.notice = "“\(watch.title)” has changed."
                case .priceDropped(let from, let to): model.notice = "“\(watch.title)”: price dropped from \(from.formatted()) to \(to.formatted())."
                }
                model.watchedPages[item.key] = PageWatch(title: watch.title, digest: PageDigest.of(text), firstPrice: PriceFinder.firstPrice(in: text) ?? watch.firstPrice, checked: Date())
            }
            model.closeTab(id: tab.id, force: true)
        }
        saveMap("scheduled_checks", "list", schedule)
    }

    // MARK: Site rules

    /// Re-reads the rules and workflows after sync changed them.
    func reloadSyncedRules() {
        guard let model else { return }
        func get(_ key: String) -> String? { (try? model.core.getSetting(key: key)) ?? nil }
        siteRules = BrowserModel.decodeMap(get("site_open_rules"), as: [SiteOpenRule].self)["list"] ?? []
        workflows = BrowserModel.decodeMap(get("workflows"), as: [Workflow].self)["list"] ?? []
    }

    func setSiteRules(_ list: [SiteOpenRule]) { siteRules = list; saveMap("site_open_rules", "list", list) }

    @discardableResult
    func addSiteRule(host: String, action: SiteOpenRule.Action) -> Bool {
        guard let model, let clean = SiteOpenRule.cleanHost(host) else { return false }
        let rule = SiteOpenRule(host: clean, action: action)
        guard SiteOpenRules.canAdd(rule, to: siteRules, containers: model.containers, groups: model.groupNames, workspaces: model.workspaces.map(\.name)) else { return false }
        setSiteRules(siteRules + [rule])
        return true
    }

    // MARK: Files

    func setDownloadRules(_ list: [DownloadRule]) { downloadRules = list; model?.downloads.rules = list; saveMap("download_rules", "list", list) }

    func addDownloadRule(host: String, kind: DownloadRule.Kind, folder: String) -> Bool {
        guard let clean = DownloadRule.cleanFolder(folder), downloadRules.count < 50 else { return false }
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.contains("/"), !h.contains(" ") else { return false }
        let rule = DownloadRule(host: h, kind: kind, folder: clean)
        setDownloadRules(downloadRules.filter { $0.id != rule.id } + [rule])
        return true
    }

    func scanDuplicates() { duplicates = DuplicateFiles.find(in: DownloadCoordinator.directory) }

    // MARK: Developer

    /// Reads the page in front. Private tabs are not read.
    func inspectPage() async {
        guard let tab = model?.active, !tab.isPrivate, let raw = await tab.engine.pageDiagnostics() else { snapshot = nil; return }
        snapshot = DevSnapshot(raw: raw, page: tab.url, taken: Date())
    }

    func runScratch(_ code: String) async {
        guard let tab = model?.active, !tab.isPrivate else { scratchOutput = "Scratchpad code does not run in private tabs."; return }
        scratchOutput = await tab.engine.runScratch(code)
    }

    /// Lets the person click an element on the page, then describes it. Private tabs are not read.
    func pickElement() async {
        guard let tab = model?.active, !tab.isPrivate, !tab.isBlank else { model?.notice = "Open a normal page first."; return }
        picking = true
        model?.sheet = nil                    // the page has to be in view to click on it
        picked = PickedElement(await tab.engine.pickElement())
        picking = false
        if picked != nil { model?.sheet = .workbench }
    }

    func cancelPick() { model?.active?.engine.cancelPicking() }

    func setInspectable(_ on: Bool) {
        inspectable = on
        for tab in model?.tabs ?? [] { tab.engine.setInspectable(on) }
    }

    func exportHAR() {
        guard let snapshot else { return }
        let data = HARWriter.har(page: snapshot.page, entries: snapshot.resources, started: snapshot.taken.addingTimeInterval(-(snapshot.resources.map { $0.startMs + $0.durationMs }.max() ?? 0) / 1000))
        save(data, name: "page-\(Int(snapshot.taken.timeIntervalSince1970)).har")
    }

    func exportWebArchive() async {
        guard let tab = model?.active, !tab.isPrivate, let data = await tab.engine.webArchive() else { model?.notice = "This page cannot be saved as a web archive."; return }
        save(data, name: (tab.title.isEmpty ? "page" : tab.title).replacingOccurrences(of: "/", with: "-") + ".webarchive")
    }

    /// A picture of the page (the visible part, or all of it), saved to Downloads. Private tabs are not captured.
    func capturePage(fullPage: Bool) async {
        guard let tab = model?.active, !tab.isPrivate, let data = await tab.engine.screenshot(fullPage: fullPage) else { model?.notice = "This page cannot be captured."; return }
        let host = tab.url?.host ?? "page"
        save(data, name: "\(host) \(fullPage ? "full page" : "view").png")
    }

    func save(_ data: Data, name: String) {
        let url = DownloadCoordinator.directory.appendingPathComponent(DownloadRouting.uniqueName(name) { FileManager.default.fileExists(atPath: DownloadCoordinator.directory.appendingPathComponent($0).path) })
        do { try data.write(to: url, options: .atomic); model?.notice = "Saved \(url.lastPathComponent) to Downloads." }
        catch { model?.notice = "Could not save the file." }
    }

    // MARK: Extensions

    func conflicts() -> [ExtensionConflict] { ExtensionConflicts.detect(model?.extensionCenter.manifestSummaries() ?? []) }

    func applyPreset(_ preset: ExtensionPermissionPreset, to id: String) {
        guard let center = model?.extensionCenter else { return }
        center.setSiteAccess(id, preset.siteAccess)
        for row in center.permissionRows(id) where !row.isSite {
            let want = preset == .cautious ? !ExtensionPermissionPreset.highRisk.contains(row.key) : true
            if row.granted != want { center.setPermission(id, key: row.key, isSite: false, granted: want) }
        }
        model?.notice = "Applied “\(preset.title)”."
    }

    /// Which extensions run in a workspace. A workspace with no list runs whatever is on.
    func setExtensions(_ ids: [String]?, forWorkspace name: String) {
        extensionProfiles[name] = ids
        guard let model else { return }
        model.saveSetting("extension_profiles", model.encodedMap(extensionProfiles))
    }

    func applyExtensionProfile(forWorkspace name: String) async {
        guard let model, let wanted = extensionProfiles[name] else { return }
        for item in model.extensionCenter.extensions {
            let on = wanted.contains(item.id)
            if item.enabled != on { await model.extensionCenter.setEnabled(item.id, on) }
        }
    }

    // MARK: Health

    func health() -> HealthSnapshot {
        guard let model else { return HealthSnapshot() }
        var h = HealthSnapshot()
        h.tabs = model.tabs.count
        h.sleeping = model.tabs.filter(\.isDiscarded).count
        h.privateTabs = model.tabs.filter(\.isPrivate).count
        h.appMemory = HealthSnapshot.footprint()
        h.extensionsOn = model.extensionCenter.extensions.filter(\.enabled).count
        h.extensionsTotal = model.extensionCenter.extensions.count
        h.proxy = model.proxyEnabled ? (model.proxy.map { "\($0.kind.title) \($0.host):\($0.port)" } ?? "on, not set") : "off"
        h.webRTCBlocked = model.blockWebRTC
        h.deleteRules = model.siteDeleteRules.count
        h.temporaryPermissions = model.tempPermissions.count
        h.failedDownloads = model.downloads.interrupted.count
        h.recentPermissionChanges = model.permissionLog.prefix(5).map { "\($0.allowed ? "Allowed" : "Refused") \($0.kinds.joined(separator: ", ")) for \($0.origin)" }
        h.lastSync = model.lastSync
        h.syncDevices = model.syncDevices.count
        h.conflicts = model.syncConflicts.count
        h.openedAfterCrash = model.safeStart
        h.profileBytes = HealthSnapshot.bytes(in: model.profileFolder)
        return h
    }
}

/// What the developer tools read from a page in one go.
struct DevSnapshot: Equatable {
    var page: URL?
    var taken: Date
    var resources: [ResourceEntry]
    var storage: [StorageItem]
    var errors: [String]
    var performance: PagePerformance

    init(raw: [String: Any], page: URL?, taken: Date) {
        self.page = page; self.taken = taken
        resources = (raw["resources"] as? [[String: Any]] ?? []).compactMap(ResourceEntry.init)
        func items(_ key: String, _ area: StorageItem.Area) -> [StorageItem] {
            (raw[key] as? [[String: Any]] ?? []).compactMap { d in
                guard let k = d["key"] as? String else { return nil }
                return StorageItem(area: area, key: k, valueSize: (d["size"] as? NSNumber)?.intValue ?? 0, preview: StorageItem.preview(d["value"] as? String ?? "", key: k))
            }
        }
        storage = items("local", .local) + items("session", .session) + items("cookies", .cookie)
        errors = (raw["errors"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        performance = PagePerformance(raw["perf"] as? [String: Any] ?? [:])
    }
}

/// The browser's own account of how it is doing. WebKit does not report memory or processor use per tab or per extension, so those are not guessed.
struct HealthSnapshot: Equatable {
    var tabs = 0, sleeping = 0, privateTabs = 0
    var appMemory = 0
    var extensionsOn = 0, extensionsTotal = 0
    var proxy = "off"
    var webRTCBlocked = false
    var deleteRules = 0, temporaryPermissions = 0
    var failedDownloads = 0
    var recentPermissionChanges: [String] = []
    var lastSync: Date?
    var syncDevices = 0, conflicts = 0
    var openedAfterCrash = false
    var profileBytes = 0

    /// Memory the app itself holds. Pages and extensions run in separate WebKit processes that are not counted here.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func bytes(in folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return walker.reduce(0) { $0 + ((($1 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? 0) }
    }
}

extension BrowserModel {
    var workbench: Workbench {
        if let existing = workbenchBacking { return existing }
        let bench = Workbench(model: self)
        workbenchBacking = bench
        return bench
    }

    /// Every external action goes through here.
    func handleExternal(_ url: URL) {
        if let action = URLAction.parse(url) { workbench.handle(action) } else { openIncoming(url) }
    }
}

extension BrowserModel {
    /// The address a typed search leads to with the chosen search engine.
    func searchURL(for text: String) -> URL? {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: searchTemplate.replacingOccurrences(of: "{}", with: encoded))
    }
}


#if os(macOS)
import AppKit
extension BrowserModel {
    /// Resizes the window in front so its content area is the size of a common screen (the part that fits on this screen).
    func resizeWindow(to preset: ViewportPreset) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let screen = window.screen?.visibleFrame.size else { return }
        window.setContentSize(preset.fitted(to: screen))
        notice = "Window size: \(preset.title), \(preset.summary)."
    }
}
#endif
