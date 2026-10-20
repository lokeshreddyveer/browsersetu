import SwiftUI

/// The kinds of thing sync can carry, each with its own switch.
enum SyncCategory: String, CaseIterable, Codable, Identifiable {
    case bookmarks, workspaces, sessions, openTabs, settings, siteRules, history, passwords
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookmarks: "Bookmarks"
        case .workspaces: "Workspaces"
        case .sessions: "Saved sessions"
        case .openTabs: "Open tabs"
        case .settings: "Settings and themes"
        case .siteRules: "Site rules and styles"
        case .history: "History"
        case .passwords: "Saved passwords"
        }
    }

    var detail: String {
        switch self {
        case .bookmarks: "Bookmarks and favorites, and the folders they are in."
        case .workspaces: "Workspace names, icons and colours."
        case .sessions: "Sessions you saved, with each page's place."
        case .openTabs: "So you can reopen this device's tabs on another, and send tabs between devices."
        case .settings: "Search engine, appearance, themes, what the start page shows. Layouts stay on each device."
        case .siteRules: "Per-site zoom, notes, style sheets, permissions that expire, JavaScript and sleep choices, containers, and rules for where sites open."
        case .history: "The 800 pages you visited most recently, and deletions. Never from private tabs."
        case .passwords: "Passwords saved in this browser. They are scrambled with your sync passphrase."
        }
    }

    var symbol: String {
        switch self {
        case .bookmarks: "star"
        case .workspaces: "square.grid.2x2"
        case .sessions: "clock.arrow.circlepath"
        case .openTabs: "rectangle.on.rectangle"
        case .settings: "gearshape"
        case .siteRules: "slider.horizontal.3"
        case .history: "clock"
        case .passwords: "key"
        }
    }

    /// Switches that are in the set `syncCategorySet`. Settings and passwords keep their own older switches.
    static let defaultOn: Set<SyncCategory> = [.bookmarks, .workspaces, .sessions, .openTabs]
}

/// A tab one device sent to another.
struct SentTab: Codable, Equatable, Identifiable {
    var id: String
    /// The id of the device it is for.
    var to: String
    var fromName: String
    var url: String
    var title: String
    var sent: Double

    static let lifetime: Double = 7 * 24 * 3600

    /// A web address and nothing else: no scripts, files or app links ever arrive this way.
    var isSafe: Bool {
        guard url.count <= 2048, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host?.isEmpty == false else { return false }
        return true
    }
}

/// What the Sync panel says about the state of sync, in one word and one reason.
enum SyncHealth: Equatable {
    case off
    case needsICloud
    case needsPassphrase
    case waiting(Int)
    case syncing
    case problem(String)
    case ok(Date)
    case idle

    var title: String {
        switch self {
        case .off: "Sync is off"
        case .needsICloud: "Not signed in to iCloud"
        case .needsPassphrase: "Needs a passphrase"
        case .waiting(let n): "\(n) device\(n == 1 ? "" : "s") waiting for approval"
        case .syncing: "Syncing…"
        case .problem: "Sync has a problem"
        case .ok: "Up to date"
        case .idle: "Ready"
        }
    }

    var symbol: String {
        switch self {
        case .off: "icloud.slash"
        case .needsICloud, .needsPassphrase, .waiting: "exclamationmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .problem: "xmark.icloud"
        case .ok: "checkmark.icloud"
        case .idle: "icloud"
        }
    }

    var tint: Color {
        switch self {
        case .ok: .green
        case .problem: .red
        case .needsICloud, .needsPassphrase, .waiting: .orange
        default: .secondary
        }
    }
}

extension BrowserModel {
    // MARK: What is switched on

    func syncs(_ category: SyncCategory) -> Bool {
        switch category {
        case .settings: syncSettingsToo
        case .passwords: syncPasswords
        default: syncCategorySet.contains(category)
        }
    }

    func setSync(_ category: SyncCategory, _ on: Bool) {
        switch category {
        case .settings: syncSettingsToo = on
        case .passwords: syncPasswords = on
        default:
            if on { syncCategorySet.insert(category) } else { syncCategorySet.remove(category) }
            saveSetting("sync_categories", encodedMap(["list": syncCategorySet.map(\.rawValue).sorted()]))
        }
        if on { Task { await syncNowCloud() } } else { scheduleCloudPush() }
    }

    func loadSyncAdvanced(_ get: (String) -> String?) {
        if let stored = get("sync_categories") {
            let names = Self.decodeMap(stored, as: [String].self)["list"] ?? []
            syncCategorySet = Set(names.compactMap(SyncCategory.init(rawValue:)))
        } else {
            // Per-site settings used to travel with "settings"; whoever had that on keeps getting them.
            syncCategorySet = SyncCategory.defaultOn.union(syncSettingsToo ? [.siteRules] : [])
        }
        outbox = (Self.decodeMap(get("sync_outbox"), as: [SentTab].self)["list"] ?? []).filter { Date().timeIntervalSince1970 - $0.sent < SentTab.lifetime }
        inbox = (Self.decodeMap(get("sync_inbox"), as: [SentTab].self)["list"] ?? []).filter { $0.isSafe }
        sentSeen = Set(Self.decodeMap(get("sync_sent_seen"), as: [String].self)["list"] ?? [])
        lastPush = get("sync_last_push").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        lastPull = get("sync_last_pull").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: Which settings a category covers

    func syncSettingAllowedOut(_ key: String) -> Bool {
        SyncRules.category(forSetting: key) == .settings || syncs(.siteRules)
    }

    func syncSettingAllowedIn(_ key: String) -> Bool {
        SyncRules.category(forSetting: key) == .settings ? syncSettingsToo : syncs(.siteRules)
    }

    // MARK: History

    static let syncHistoryLimit = 800
    static let syncHistoryDays: Double = 90

    func currentHistory() -> [String: SyncVisit] {
        let since = Date().timeIntervalSince1970 - Self.syncHistoryDays * 86_400
        var out: [String: SyncVisit] = [:]
        for h in ((try? core.recentHistory(limit: UInt32(Self.syncHistoryLimit))) ?? []) where Double(h.lastVisit) >= since && ["http", "https"].contains(URL(string: h.url)?.scheme?.lowercased() ?? "") {
            out[h.url] = SyncVisit(title: String(h.title.prefix(200)), last: Double(h.lastVisit))
        }
        return out
    }

    /// Notes visits and deletions. A page that only fell out of the window of recent pages is not a deletion, so it is left alone.
    func observeHistory(now: Date) {
        guard syncs(.history) else { syncLedger.history = [:]; return }
        let current = currentHistory()
        let device = syncDeviceID
        let windowFull = current.count >= Self.syncHistoryLimit
        let oldestShown = current.values.map(\.last).min() ?? 0
        for (url, visit) in current where syncLedger.history[url]?.value != visit {
            syncLedger.history[url] = SyncCell(stamp: syncClock.stamp(now: now, device: device), value: visit)
        }
        for (url, cell) in syncLedger.history {
            guard let value = cell.value, current[url] == nil else { continue }
            if windowFull, value.last <= oldestShown { continue }
            syncLedger.history[url] = SyncCell(stamp: syncClock.stamp(now: now, device: device), value: nil)
        }
    }

    /// Adds the pages other devices visited (newer than what is here) and removes the ones they deleted. Returns how many pages changed.
    func applyHistory(_ merged: SyncState, outcome: inout SyncRules.Outcome) {
        guard syncs(.history) else { return }
        var local: [String: Double] = [:]
        for h in ((try? core.recentHistory(limit: 20_000)) ?? []) { local[h.url] = Double(h.lastVisit) }
        var visits: [ImportedVisit] = []
        var deletions: [String] = []
        for (url, cell) in merged.history {
            if let visit = cell.value {
                guard ["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "") else { continue }
                if let have = local[url], have >= visit.last { continue }
                visits.append(ImportedVisit(url: url, title: String(visit.title.prefix(300)), lastVisit: Int64(visit.last), visitCount: 1))
            } else if local[url] != nil { deletions.append(url) }
        }
        if !visits.isEmpty, let written = try? core.importHistory(visits: Array(visits.prefix(2_000))) { outcome.historyChanged += Int(written) }
        for url in deletions.prefix(2_000) where (try? core.deleteHistoryEntry(url: url)) != nil { outcome.historyChanged += 1 }
    }

    // MARK: Sending a tab

    /// Approved devices a tab can be sent to.
    var sendTargets: [SyncDevice] { iCloudSync ? syncDevices.filter { $0.status == .approved } : [] }

    @discardableResult
    func sendTab(_ tab: TabController, to device: SyncDevice) -> Bool {
        guard !tab.isPrivate, !tab.isBlank, let url = tab.url, let clean = Continuity.handoffURL(isPrivate: false, isBlank: false, url: url) else {
            notice = tab.isPrivate ? "Private tabs are never sent." : "That page cannot be sent."
            return false
        }
        let item = SentTab(id: UUID().uuidString, to: device.id, fromName: syncDeviceName, url: clean.absoluteString, title: String(tab.displayTitle.prefix(200)), sent: Date().timeIntervalSince1970)
        guard item.isSafe else { notice = "That page cannot be sent."; return false }
        outbox = Array((outbox + [item]).suffix(30))
        saveSetting("sync_outbox", encodedMap(["list": outbox]))
        logSync("Sent “\(item.title)” to \(device.name)")
        notice = "Sent to \(device.name)."
        Task { await syncNowCloud() }
        return true
    }

    /// Tabs addressed to this device in a snapshot from another one. Each arrives once.
    func receiveSentTabs(_ snapshot: BackupPayload, outcome: inout SyncRules.Outcome) {
        guard let items = snapshot.outbox else { return }
        let now = Date().timeIntervalSince1970
        var fresh: [SentTab] = []
        for item in items where item.to == syncDeviceID && !sentSeen.contains(item.id) && item.isSafe && now - item.sent < SentTab.lifetime && item.sent <= now + 300 {
            sentSeen.insert(item.id)
            fresh.append(item)
        }
        guard !fresh.isEmpty else { return }
        inbox = Array((inbox + fresh).suffix(30))
        saveSetting("sync_inbox", encodedMap(["list": inbox]))
        saveSetting("sync_sent_seen", encodedMap(["list": Array(sentSeen.sorted().suffix(300))]))
        outcome.tabsReceived += fresh.count
        notice = fresh.count == 1 ? "\(fresh[0].fromName) sent you “\(fresh[0].title.isEmpty ? displayHost(URL(string: fresh[0].url)) : fresh[0].title)”." : "\(fresh.count) tabs were sent to this device."
        logSync("Received \(fresh.count) tab\(fresh.count == 1 ? "" : "s") from \(fresh[0].fromName)")
    }

    func openSentTab(_ item: SentTab) {
        guard item.isSafe else { return }
        open(urlString: item.url, newTab: true)
        dismissSentTab(item)
    }

    func dismissSentTab(_ item: SentTab) {
        inbox.removeAll { $0.id == item.id }
        saveSetting("sync_inbox", encodedMap(["list": inbox]))
    }

    // MARK: Status

    var syncHealth: SyncHealth {
        guard iCloudSync else { return .off }
        guard CloudSync.available else { return .needsICloud }
        guard syncPassphrase?.isEmpty == false else { return .needsPassphrase }
        if isSyncing { return .syncing }
        let waiting = syncDevices.filter { $0.status == .pending }.count
        if waiting > 0 { return .waiting(waiting) }
        if let error = syncError { return .problem(error) }
        if let done = [lastPush, lastPull].compactMap({ $0 }).max() { return .ok(done) }
        return .idle
    }

    /// How full iCloud's small sync space is, 0 to 1.
    var syncSpaceUsed: Double {
        guard let cloud = cloudSync else { return 0 }
        return min(1, Double(cloud.bytesInUse) / Double(CloudSync.storeBudget))
    }

    func recordSyncOutcome(push: Bool, error: String?) {
        let now = Date()
        if let error { syncError = error; return }
        syncError = nil
        if push { lastPush = now; saveSetting("sync_last_push", String(now.timeIntervalSince1970)) }
        else { lastPull = now; saveSetting("sync_last_pull", String(now.timeIntervalSince1970)) }
    }
}

// MARK: - Screens

/// The state of sync at a glance, at the top of the Sync panel.
struct SyncStatusRow: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let health = model.syncHealth
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: health.symbol).font(.title3).foregroundStyle(health.tint).frame(width: 26)
                    .symbolEffect(.pulse, isActive: health == .syncing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health.title).font(.callout.weight(.semibold))
                    Text(detail(health)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.iCloudSync { Button("Sync Now") { Task { await model.syncNowCloud() } }.disabled(health == .syncing || health == .needsPassphrase || health == .needsICloud) }
            }
            if model.iCloudSync, model.cloudSync != nil {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: model.syncSpaceUsed).tint(model.syncSpaceUsed > 0.85 ? .orange : .accentColor)
                    Text("iCloud sync space: \(Int((model.syncSpaceUsed * 100).rounded()))% used")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .motion(.easeOut(duration: 0.2), value: health)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync-status")
    }

    private func detail(_ health: SyncHealth) -> String {
        func when(_ date: Date?) -> String { date.map { $0.formatted(.relative(presentation: .named)) } ?? "never" }
        switch health {
        case .off: return "Turn on iCloud sync to keep your devices the same."
        case .needsICloud: return "Sign in to iCloud in the system Settings."
        case .needsPassphrase: return "Choose the same passphrase on every device."
        case .waiting: return "Approve them below before anything is shared."
        case .syncing: return "Sending and receiving."
        case .problem(let text): return text
        case .ok: return "Sent \(when(model.lastPush)) · received \(when(model.lastPull))"
        case .idle: return "Nothing has been sent or received yet."
        }
    }
}

/// One switch for each kind of thing.
struct SyncCategoriesRows: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ForEach(SyncCategory.allCases) { category in
            Toggle(isOn: Binding(get: { model.syncs(category) }, set: { model.setSync(category, $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(category.title, systemImage: category.symbol)
                    Text(category.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("sync-\(category.rawValue)")
        }
    }
}

/// Tabs other devices sent to this one.
struct SentTabsRows: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if !model.inbox.isEmpty {
            ForEach(model.inbox) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title.isEmpty ? displayHost(URL(string: item.url)) : item.title).lineLimit(1)
                        Text("From \(item.fromName) · \(displayHost(URL(string: item.url)))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { model.openSentTab(item) }
                    Button { model.dismissSentTab(item) } label: { Image(systemName: "xmark").accessibilityLabel("Dismiss") }.buttonStyle(.borderless)
                }
            }
        }
    }
}

/// "Send to …" for a tab: one entry for each approved device.
struct SendTabMenu: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        let targets = model.sendTargets
        if !targets.isEmpty, !tab.isPrivate, !tab.isBlank {
            Menu("Send to Device") {
                ForEach(targets) { device in Button(device.name) { model.sendTab(tab, to: device) } }
            }
        }
    }
}
