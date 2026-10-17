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

    /// This device's snapshot: bookmarks, the settings that mean the same everywhere, and its open (non-private) tabs.
    func makeSyncSnapshot() -> BackupPayload {
        let bookmarks = ((try? core.listBookmarks(query: "")) ?? []).map { BackupPayload.Bookmark(url: $0.url, title: $0.title, folder: $0.folder) }
        var settings: [String: String] = [:]
        for key in SyncRules.settingKeys.sorted() { if let value = (try? core.getSetting(key: key)) ?? nil { settings[key] = value } }
        let tabs = tabs.filter { !$0.isPrivate && !$0.isBlank }.compactMap { tab in
            tab.url.map { BackupPayload.Tab(url: $0.absoluteString, title: tab.displayTitle) }
        }
        var snapshot = BackupPayload(created: Date(), bookmarks: bookmarks, settings: settings)
        snapshot.tabs = SyncRules.cleanTabs(tabs)
        snapshot.device = syncDeviceName
        snapshot.deviceID = syncDeviceID
        snapshot.syncGroup = syncGroupName
        return snapshot
    }

    /// Takes in another device's snapshot. Bookmarks are added (nothing is ever removed), tabs are listed under that device, and settings are
    /// applied only if the person turned that on and the snapshot is newer than the last one applied.
    @discardableResult
    func applySyncSnapshot(_ snapshot: BackupPayload) -> SyncRules.Outcome {
        var outcome = SyncRules.Outcome()
        let existing = Set(((try? core.listBookmarks(query: "")) ?? []).map(\.url))
        for b in SyncRules.bookmarksToAdd(remote: snapshot.bookmarks, existing: existing) {
            if (try? core.addBookmark(url: b.url, title: b.title, folder: b.folder)) != nil { outcome.bookmarksAdded += 1 }
        }
        if syncSettingsToo, snapshot.created > lastSyncedSettings, syncAskOnConflict {
            // Asked, not decided: every setting that differs waits for the user's choice.
            for (key, value) in SyncRules.acceptedSettings(snapshot.settings) {
                let mine = ((try? core.getSetting(key: key)) ?? nil) ?? ""
                if mine != value, !syncConflicts.contains(where: { $0.key == key }) {
                    syncConflicts.append(SyncConflict(key: key, mine: mine, theirs: value, device: snapshot.device ?? "another device"))
                }
            }
            lastSyncedSettings = snapshot.created
            saveSetting("sync_settings_date", String(snapshot.created.timeIntervalSince1970))
        } else if syncSettingsToo, snapshot.created > lastSyncedSettings {
            for (key, value) in SyncRules.acceptedSettings(snapshot.settings) where (try? core.setSetting(key: key, value: value)) != nil { outcome.settingsApplied += 1 }
            lastSyncedSettings = snapshot.created
            saveSetting("sync_settings_date", String(snapshot.created.timeIntervalSince1970))
            if outcome.settingsApplied > 0 { loadUISettings() }
        }
        if let device = snapshot.device, let tabs = snapshot.tabs {
            let clean = SyncRules.cleanTabs(tabs)
            outcome.tabs = clean.count
            var list = remoteTabs.filter { $0.device != device }
            if !clean.isEmpty { list.append(RemoteTabs(device: device, date: snapshot.created, tabs: clean)) }
            remoteTabs = list
            saveSetting("sync_remote_tabs", encodedMap(["list": list]))
        }
        if outcome.bookmarksAdded > 0 { refreshBookmarkState() }
        lastSync = Date()
        saveSetting("sync_last", String(Date().timeIntervalSince1970))
        return outcome
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
            logSync("Took \(conflict.device)’s value for \(conflict.key)")
        } else {
            logSync("Kept this device’s value for \(conflict.key)")
        }
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
        await pushCloud(passphrase: phrase)
        await pullCloud()
    }

    /// The heavy part (turning the passphrase into a key and encrypting) runs on a background thread; only the small hand-over happens here.
    func pushCloud(passphrase: String) async {
        let snapshot = makeSyncSnapshot()
        let sealed = await Task.detached(priority: .utility) { try? SyncRules.sealedFitting(snapshot, passphrase: passphrase) }.value
        guard let sealed else { syncStatus = "Could not prepare the data to sync."; return }
        guard cloudSync?.push(sealed, deviceID: syncDeviceID) == true else {
            syncStatus = "There is too much to sync: iCloud’s sync space (1 MB for everything) would be exceeded. Remove some bookmarks or turn off tab sync."
            logSync("Could not upload: too large for iCloud’s sync space")
            return
        }
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
                if outcome.bookmarksAdded > 0 || outcome.settingsApplied > 0 { logSync("Synced with \(payload.device ?? "a device"): \(outcome.bookmarksAdded) bookmarks added") }
            case .pending: waiting += 1
            case .blocked: continue
            }
        }
        if waiting > 0 { syncStatus = "\(waiting) device\(waiting == 1 ? " is" : "s are") waiting for your approval below." }
        else { syncStatus = wrongPhrase > 0 && taken == 0 ? "Another device uses a different sync passphrase." : (taken == 0 ? "No other device has synced yet." : "Synced.") }
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
