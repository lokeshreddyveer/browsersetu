import SwiftUI

extension BrowserModel {
    // MARK: What is shared

    var syncDeviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    // MARK: What this device has now

    private func currentBookmarks() -> [String: SyncBookmark] {
        var out: [String: SyncBookmark] = [:]
        for b in ((try? core.listBookmarks(query: "")) ?? []).prefix(SyncRules.maxBookmarks) where ["http", "https"].contains(URL(string: b.url)?.scheme?.lowercased() ?? "") {
            out[b.url] = SyncBookmark(title: b.title, folder: b.folder)
        }
        return out
    }

    private func currentSettings() -> [String: String] {
        var out: [String: String] = [:]
        for key in SyncRules.settingKeys { if let value = (try? core.getSetting(key: key)) ?? nil { out[key] = value } }
        return out
    }

    private func currentWorkspaces() -> [String: SyncWorkspace] {
        Dictionary(workspaces.map { ($0.name, SyncWorkspace(icon: $0.icon, preset: $0.preset, accent: $0.accent)) }, uniquingKeysWith: { first, _ in first })
    }

    private func currentSessions() -> [String: SavedSession] { Dictionary(savedSessions.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first }) }

    private func currentLogins() -> [String: SyncLogin] {
        Dictionary(WebLoginVault.list(profile: profileName).map { ($0.id, SyncLogin(origin: $0.origin, user: $0.user, password: $0.password)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Stamps what changed on this device since the last sync: new or edited things get a fresh stamp, removed things become tombstones.
    func observeLocalChanges(now: Date = Date()) {
        let device = syncDeviceID
        // A kind of thing that is switched off is neither sent nor taken in. Its part of the ledger is simply dropped (not turned into deletions), so switching it
        // off never deletes anything on another device.
        if syncs(.bookmarks) { SyncMerge.observe(ledger: &syncLedger.bookmarks, current: currentBookmarks(), clock: &syncClock, device: device, now: now) } else { syncLedger.bookmarks = [:] }
        if syncs(.workspaces) { SyncMerge.observe(ledger: &syncLedger.workspaces, current: currentWorkspaces(), clock: &syncClock, device: device, now: now) } else { syncLedger.workspaces = [:] }
        if syncs(.sessions) { SyncMerge.observe(ledger: &syncLedger.sessions, current: currentSessions(), clock: &syncClock, device: device, now: now) } else { syncLedger.sessions = [:] }
        // Settings are published unless they are site rules that are switched off; whether another device takes them in is that device's own choice.
        syncLedger.settings = syncLedger.settings.filter { syncSettingAllowedOut($0.key) }
        SyncMerge.observe(ledger: &syncLedger.settings, current: currentSettings().filter { syncSettingAllowedOut($0.key) }, clock: &syncClock, device: device, now: now)
        if syncPasswords { SyncMerge.observe(ledger: &syncLedger.logins, current: currentLogins(), clock: &syncClock, device: device, now: now) }
        else { syncLedger.logins = [:] }
        observeHistory(now: now)
        syncLedger = SyncMerge.pruned(syncLedger, now: now)
    }

    private func saveSyncLedger() {
        saveSetting("sync_ledger", encodedMap(["state": syncLedger]))
        saveSetting("sync_clock", encodedMap(["clock": syncClock]))
        saveSetting("sync_seq", String(syncSeq))
        saveSetting("sync_seen", encodedMap(syncSeen))
    }

    /// This device's snapshot: every synced item with its stamp, this device's open (non-private) tabs, and the names of its extensions.
    func makeSyncSnapshot() -> BackupPayload {
        observeLocalChanges()
        syncSeq += 1
        saveSyncLedger()
        let tabs = tabs.filter { !$0.isPrivate && !$0.isBlank }.compactMap { tab in
            tab.url.map { BackupPayload.Tab(url: $0.absoluteString, title: tab.displayTitle, group: tab.group.isEmpty ? nil : tab.group) }
        }
        var snapshot = BackupPayload(created: Date(), bookmarks: [], settings: [:])
        snapshot.state = syncLedger
        snapshot.seq = syncSeq
        snapshot.tabs = syncs(.openTabs) ? SyncRules.cleanTabs(tabs) : []
        snapshot.outbox = outbox.filter { Date().timeIntervalSince1970 - $0.sent < SentTab.lifetime }
        snapshot.extensions = Array(extensionCenter.extensions.prefix(60).map { SyncExtension(name: $0.name, chromeID: nil, version: $0.version) })
        snapshot.device = syncDeviceName
        snapshot.deviceID = syncDeviceID
        snapshot.syncGroup = syncGroupName
        return snapshot
    }

    /// Takes in another device's snapshot. Items are merged by stamp, so the result is the same whatever order devices sync in; a snapshot that is not newer than the last
    /// one taken from that device is ignored. A snapshot from an older version of the app (no merge state) can only add bookmarks.
    @discardableResult
    func applySyncSnapshot(_ snapshot: BackupPayload) -> SyncRules.Outcome {
        var outcome = SyncRules.Outcome()
        if let remote = snapshot.state {
            if let device = snapshot.deviceID, let seq = snapshot.seq, let seen = syncSeen[device], seq <= seen {
                logSync("Ignored an out-of-date copy from \(snapshot.device ?? "a device")")
                return outcome
            }
            observeLocalChanges()                                   // this device's own newer edits are stamped before anything is compared
            let merged = SyncMerge.merge(syncLedger, remote)
            applyMergedState(merged, from: snapshot, outcome: &outcome)
            syncClock.observe(SyncStamp(time: SyncMerge.highestStamp(in: merged), device: syncDeviceID))
            if let device = snapshot.deviceID, let seq = snapshot.seq { syncSeen[device] = seq }
            saveSyncLedger()
        } else {
            let existing = Set(((try? core.listBookmarks(query: "")) ?? []).map(\.url))
            for b in SyncRules.bookmarksToAdd(remote: snapshot.bookmarks, existing: existing) where (try? core.addBookmark(url: b.url, title: b.title, folder: b.folder)) != nil { outcome.bookmarksAdded += 1 }
        }
        receiveSentTabs(snapshot, outcome: &outcome)
        if let device = snapshot.device {
            let clean = syncs(.openTabs) ? SyncRules.cleanTabs(snapshot.tabs ?? []) : []
            outcome.tabs = clean.count
            var list = remoteTabs.filter { $0.device != device }
            if !clean.isEmpty { list.append(RemoteTabs(device: device, date: snapshot.created, tabs: clean)) }
            remoteTabs = list
            saveSetting("sync_remote_tabs", encodedMap(["list": list]))
            if let extensions = snapshot.extensions { remoteExtensions[device] = extensions }
        }
        if outcome.bookmarksAdded > 0 || outcome.bookmarksRemoved > 0 || outcome.bookmarksChanged > 0 { refreshBookmarkState() }
        lastSync = Date()
        saveSetting("sync_last", String(Date().timeIntervalSince1970))
        return outcome
    }

    private func applyMergedState(_ merged: SyncState, from snapshot: BackupPayload, outcome: inout SyncRules.Outcome) {
        var kept = merged
        // Bookmarks.
        let bookmarkPlan = syncs(.bookmarks) ? SyncMerge.plan(merged: merged.bookmarks, current: currentBookmarks()) : SyncMerge.Plan<SyncBookmark>()
        if !syncs(.bookmarks) { kept.bookmarks = syncLedger.bookmarks }
        for (url, value) in bookmarkPlan.upsert.sorted(by: { $0.key < $1.key }) {
            let existed = (try? core.isBookmarked(url: url)) ?? false
            if existed { try? core.removeBookmark(url: url) }
            if (try? core.addBookmark(url: url, title: value.title, folder: value.folder)) != nil { if existed { outcome.bookmarksChanged += 1 } else { outcome.bookmarksAdded += 1 } }
        }
        for url in bookmarkPlan.delete where (try? core.removeBookmark(url: url)) != nil { outcome.bookmarksRemoved += 1 }
        // Workspaces: the name, icon, colour and layout preset are shared; the window arrangement stays on each device.
        let workspacePlan = syncs(.workspaces) ? SyncMerge.plan(merged: merged.workspaces, current: currentWorkspaces()) : SyncMerge.Plan<SyncWorkspace>()
        if !syncs(.workspaces) { kept.workspaces = syncLedger.workspaces }
        for (name, value) in workspacePlan.upsert.sorted(by: { $0.key < $1.key }) {
            upsertWorkspaceFromSync(name, value)
            outcome.workspacesChanged += 1
        }
        for name in workspacePlan.delete { deleteWorkspace(name); outcome.workspacesChanged += 1 }
        if !workspacePlan.isEmpty { saveWorkspaces() }
        // Saved sessions: a session saved or deleted on another device appears or goes here.
        let sessionPlan = syncs(.sessions) ? SyncMerge.plan(merged: merged.sessions, current: currentSessions()) : SyncMerge.Plan<SavedSession>()
        if !syncs(.sessions) { kept.sessions = syncLedger.sessions }
        if !sessionPlan.isEmpty {
            var list = savedSessions.filter { !sessionPlan.delete.contains($0.id.uuidString) }
            for (_, value) in sessionPlan.upsert.sorted(by: { $0.key < $1.key }) {
                var clean = value
                clean.tabs = clean.tabs.filter { URL(string: $0.url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil } ?? false }
                clean.name = String(clean.name.prefix(60))
                guard !clean.tabs.isEmpty, !clean.name.isEmpty else { continue }
                if let i = list.firstIndex(where: { $0.id == clean.id }) { list[i] = clean } else { list.append(clean) }
                outcome.sessionsChanged += 1
            }
            setSavedSessions(Array(list.prefix(50)))
        }
        // Settings and site rules: each only if the person turned that kind on. For plain settings, when asked, every difference waits for their choice and this
        // device keeps its own value for now.
        let settingPlan = SyncMerge.plan(merged: merged.settings, current: currentSettings())
        var settingsKept = merged.settings
        var settingsChanged = false
        for (key, value) in settingPlan.upsert.sorted(by: { $0.key < $1.key }) where SyncRules.settingKeys.contains(key) {
            guard syncSettingAllowedIn(key) else { settingsKept[key] = syncLedger.settings[key]; continue }
            if syncAskOnConflict, SyncRules.category(forSetting: key) == .settings {
                let mine = ((try? core.getSetting(key: key)) ?? nil) ?? ""
                if !syncConflicts.contains(where: { $0.key == key }) { syncConflicts.append(SyncConflict(key: key, mine: mine, theirs: value, device: snapshot.device ?? "another device", theirsStamp: merged.settings[key]?.stamp)) }
                settingsKept[key] = syncLedger.settings[key]
            } else if (try? core.setSetting(key: key, value: value)) != nil { outcome.settingsApplied += 1; settingsChanged = true }
        }
        for key in merged.settings.keys where !SyncRules.settingKeys.contains(key) { settingsKept[key] = syncLedger.settings[key] }
        kept.settings = settingsKept
        if settingsChanged { loadUISettings(); workbench.reloadSyncedRules() }
        // History: only if the person turned that on.
        if syncs(.history) { applyHistory(merged, outcome: &outcome) } else { kept.history = [:] }
        // Saved passwords: only if the person turned that on.
        if syncPasswords {
            let loginPlan = SyncMerge.plan(merged: merged.logins, current: currentLogins())
            for (_, value) in loginPlan.upsert.sorted(by: { $0.key < $1.key }) {
                if WebLoginVault.save(WebLogin(origin: value.origin, user: value.user, password: value.password), profile: profileName) { outcome.loginsChanged += 1 }
            }
            for id in loginPlan.delete { if let login = WebLoginVault.list(profile: profileName).first(where: { $0.id == id }) { WebLoginVault.forget(login, profile: profileName); outcome.loginsChanged += 1 } }
        } else { kept.logins = [:] }
        syncLedger = kept
    }

    // MARK: Groups, devices and history

    var syncPassphrase: String? { SyncKeys.passphrase(profile: profileName) }

    /// Writes down what sync did, newest last, so a surprise can be explained.
    func logSync(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        syncHistory = Array((syncHistory + [formatter.string(from: Date()) + " " + text]).suffix(50))
        saveSetting("sync_history", encodedMap(["list": syncHistory]))
    }

    private func saveSyncDevices() { saveSetting("sync_devices", encodedMap(["list": syncDevices])) }

    /// The state of a device we have just heard from. A device never seen before is held back until the user approves it.
    func registerSyncDevice(id: String, name: String?) -> SyncDevice.Status {
        if let index = syncDevices.firstIndex(where: { $0.id == id }) {
            syncDevices[index].lastSeen = Date()
            if let name, !name.isEmpty { syncDevices[index].name = name }
            saveSyncDevices()
            return syncDevices[index].status
        }
        syncDevices.append(SyncDevice(id: id, name: (name?.isEmpty == false ? name! : "Another device"), status: .pending, lastSeen: Date()))
        saveSyncDevices()
        logSync("\(syncDevices.last!.name) wants to sync with this device")
        return .pending
    }

    func approveSyncDevice(_ id: String) {
        guard let index = syncDevices.firstIndex(where: { $0.id == id }) else { return }
        syncDevices[index].status = .approved
        saveSyncDevices()
        logSync("Approved \(syncDevices[index].name)")
        Task { await pullCloud() }
    }

    /// Stops using a device's data and removes its stored snapshot. A device that knows the passphrase can still write again, but it is ignored; to lock one
    /// out for good, change the passphrase on the others.
    func blockSyncDevice(_ id: String) {
        guard let index = syncDevices.firstIndex(where: { $0.id == id }) else { return }
        syncDevices[index].status = .blocked
        saveSyncDevices()
        cloudSync?.revoke(deviceID: id)
        logSync("Blocked \(syncDevices[index].name)")
    }

    func forgetSyncDevice(_ id: String) {
        syncDevices.removeAll { $0.id == id }
        saveSyncDevices()
    }

    /// Moves this profile to another sync group: this device's snapshot leaves the old one, and the new one starts fresh.
    func changeSyncGroup(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != syncGroupName else { return }
        let wasOn = cloudSync != nil
        if wasOn { stopCloudSync() }
        syncGroupName = clean
        saveSetting("sync_group", clean)
        syncDevices = []
        saveSyncDevices()
        logSync("Joined the sync group “\(clean)”")
        if wasOn { startCloudSync() }
    }

    /// Chooses between this device's value and another's for a setting that differs.
    func resolveSyncConflict(_ conflict: SyncConflict, useTheirs: Bool) {
        if useTheirs, SyncRules.settingKeys.contains(conflict.key), (try? core.setSetting(key: conflict.key, value: conflict.theirs)) != nil {
            loadUISettings()
            // Their value is adopted with its own stamp, so it stays the winner here and everywhere.
            if let stamp = conflict.theirsStamp { syncLedger.settings[conflict.key] = SyncCell(stamp: stamp, value: conflict.theirs); syncClock.observe(stamp) }
            logSync("Took \(conflict.device)’s value for \(conflict.key)")
        } else {
            // Keeping this device's value means stamping it now, so it beats the other value on every device.
            let mine = ((try? core.getSetting(key: conflict.key)) ?? nil) ?? conflict.mine
            syncLedger.settings[conflict.key] = SyncCell(stamp: syncClock.stamp(now: Date(), device: syncDeviceID), value: mine)
            logSync("Kept this device’s value for \(conflict.key)")
        }
        saveSyncLedger()
        syncConflicts.removeAll { $0.key == conflict.key }
    }

    // MARK: iCloud

    func startCloudSync() {
        guard hasStarted, iCloudSync, cloudSync == nil else { return }
        guard CloudSync.available else { syncStatus = "Sign in to iCloud in Settings to sync."; return }
        let cloud = CloudSync(group: syncGroupName)
        cloud.onChange = { [weak self] in Task { @MainActor in await self?.pullCloud() } }
        cloud.start()
        cloudSync = cloud
        Task { await syncNowCloud() }
    }

    func stopCloudSync() {
        cloudSync?.stop()
        cloudSync?.forgetThisDevice(deviceID: syncDeviceID)
        cloudSync = nil
    }

    /// Sends this device's snapshot and takes in the others'.
    func syncNowCloud() async {
        guard iCloudSync, cloudSync != nil else { return }
        guard let phrase = syncPassphrase, !phrase.isEmpty else { syncStatus = "Set a sync passphrase first. Use the same one on every device."; return }
        isSyncing = true
        defer { isSyncing = false }
        await pushCloud(passphrase: phrase)
        await pullCloud()
    }

    /// The heavy part (turning the passphrase into a key and encrypting) runs on a background thread; only the small hand-over happens here.
    func pushCloud(passphrase: String) async {
        let snapshot = makeSyncSnapshot()
        let sealed = await Task.detached(priority: .utility) { try? SyncRules.sealedFitting(snapshot, passphrase: passphrase) }.value
        guard let sealed else { syncStatus = "Could not prepare the data to sync."; recordSyncOutcome(push: true, error: "Could not prepare the data to sync."); return }
        guard cloudSync?.push(sealed, deviceID: syncDeviceID) == true else {
            syncStatus = "There is too much to sync: iCloud’s sync space (1 MB for everything) would be exceeded. Turn off history or open-tab sync, or remove some bookmarks."
            recordSyncOutcome(push: true, error: "Too much to sync for iCloud’s 1 MB space. Turn off history or open tabs, or remove some bookmarks.")
            logSync("Could not upload: too large for iCloud’s sync space")
            return
        }
        recordSyncOutcome(push: true, error: nil)
    }

    func pullCloud() async {
        guard let cloud = cloudSync, let phrase = syncPassphrase, !phrase.isEmpty else { return }
        let items = cloud.others(except: syncDeviceID)
        let group = syncGroupName
        // Opening each snapshot derives a key from the passphrase, which is slow on purpose: not on the main thread.
        let opened = await Task.detached(priority: .utility) { items.map { (id: $0.deviceID, payload: try? BackupFile.open($0.data, passphrase: phrase)) } }.value
        var wrongPhrase = 0, taken = 0, waiting = 0
        for item in opened {
            guard let payload = item.payload else { wrongPhrase += 1; continue }
            guard payload.syncGroup == group else { continue }
            switch registerSyncDevice(id: item.id, name: payload.device) {
            case .approved:
                let outcome = applySyncSnapshot(payload)
                taken += 1
                if outcome.bookmarksAdded + outcome.bookmarksRemoved + outcome.bookmarksChanged + outcome.settingsApplied + outcome.workspacesChanged + outcome.loginsChanged > 0 { logSync("Synced with \(payload.device ?? "a device"): \(outcome.bookmarksAdded) bookmarks added, \(outcome.bookmarksChanged) changed, \(outcome.bookmarksRemoved) removed, \(outcome.workspacesChanged) workspaces, \(outcome.loginsChanged) passwords") }
            case .pending: waiting += 1
            case .blocked: continue
            }
        }
        if waiting > 0 { syncStatus = "\(waiting) device\(waiting == 1 ? " is" : "s are") waiting for your approval below." }
        else { syncStatus = wrongPhrase > 0 && taken == 0 ? "Another device uses a different sync passphrase." : (taken == 0 ? "No other device has synced yet." : "Synced.") }
        if wrongPhrase > 0, taken == 0, waiting == 0 { recordSyncOutcome(push: false, error: "Another device uses a different sync passphrase.") }
        else { recordSyncOutcome(push: false, error: nil) }
    }

    /// Debounced: called when something worth sharing changed.
    func scheduleCloudPush() {
        guard iCloudSync, cloudSync != nil, let phrase = syncPassphrase, !phrase.isEmpty else { return }
        cloudPushTask?.cancel()
        cloudPushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await self?.pushCloud(passphrase: phrase)
        }
    }

    // MARK: Wi-Fi

    /// The snapshot as it goes over the Wi-Fi link. The link is already encrypted with the one-time code, so it is not sealed again.
    func wifiSnapshot() -> Data? { try? JSONEncoder().encode(makeSyncSnapshot()) }

    /// A snapshot arrived over Wi-Fi: take it in, and answer with this device's own so both sides end up the same.
    func receiveWiFiSnapshot(_ data: Data) -> Data? {
        guard let snapshot = try? JSONDecoder().decode(BackupPayload.self, from: data) else { return nil }
        guard snapshot.syncGroup == syncGroupName else {
            syncStatus = "That device syncs in the group “\(snapshot.syncGroup ?? "none")”, not “\(syncGroupName)”. Use the same group name on both."
            return nil
        }
        let outcome = applySyncSnapshot(snapshot)
        syncStatus = "Synced with \(snapshot.device ?? "another device"): \(outcome.bookmarksAdded) bookmark\(outcome.bookmarksAdded == 1 ? "" : "s") added."
        return wifiSnapshot()
    }

    func finishWiFiSync(reply: Data?, deviceName: String) {
        guard let reply, let snapshot = try? JSONDecoder().decode(BackupPayload.self, from: reply) else { syncStatus = "The other device did not answer."; return }
        guard snapshot.syncGroup == syncGroupName else {
            syncStatus = "That device syncs in the group “\(snapshot.syncGroup ?? "none")”, not “\(syncGroupName)”. Use the same group name on both."
            return
        }
        let outcome = applySyncSnapshot(snapshot)
        syncStatus = "Synced with \(snapshot.device ?? deviceName): \(outcome.bookmarksAdded) bookmark\(outcome.bookmarksAdded == 1 ? "" : "s") added, \(outcome.tabs) tab\(outcome.tabs == 1 ? "" : "s") available."
    }
}
