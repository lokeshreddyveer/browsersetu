import Foundation

/// Applying the network settings and the network policy. The scheduler stays the one authority on who runs and how many connections are open; this only gives it numbers
/// (the per-website limit on the shared connection budget, the speed limit on the shared bandwidth controller) and a separate "held by network policy" flag.
extension DownloadCoordinator {
    /// Brings every engine in line with `networkSettings`. Values are checked first, so nothing outside its range reaches an engine.
    func applyNetworkSettings() {
        let s = networkSettings.normalized()
        defer { if torrentsStarted { torrents.settingsChanged() } }          // torrents already running meet the new proxy and metered-network choices
        // Every limit is this profile's own (its tasks are told apart by `ownerID`); only the physical totals are shared. Timeout and retry count travel with the transfers
        // (`DownloadNetworkSetup`, the request policy), never through a process-wide variable.
        BandwidthController.shared.setOverallLimit(s.overallLimit, owner: ownerID)
        ConnectionBudget.shared.setHostLimit(s.perHostConnections == ConnectionBudget.perHostLimit ? nil : s.perHostConnections, owner: ownerID)
        http.multipartConnections = s.workersPerDownload
        adaptive.settingsChanged()
        // The Keychain is only asked when a proxy with a user name is actually in use.
        let needsPassword = [.http, .https, .socks5].contains(s.proxy.mode) && !s.proxy.username.isEmpty
        http.engine.applyNetwork(DownloadNetworkSetup(s, password: needsPassword ? cachedProxyPassword() : nil))
        scheduler.pump()
        evaluateNetworkHold(networkPath())
    }

    /// Holds or releases downloads as the connection and the person's settings say. A hold only affects what the policy itself stopped: a download the person paused stays paused, and
    /// one that needed the person's decision after a crash is never started here.
    func evaluateNetworkHold(_ path: PathInfo) {
        let wanted = NetworkPolicy.hold(for: path, settings: networkSettings)
        guard wanted != networkHold else { return }
        setNetworkHold(wanted)
        scheduler.policyHold = wanted != nil
        if let wanted {
            note(wanted.explanation)
            for (id, record) in ledger.records where record.protocolID == .http && record.state == .running && canPause(id) {
                policyPaused.insert(id)
                pause(id)
            }
        } else {
            note("Network is suitable again: downloads carry on")
            resumePolicyPaused(attempts: 240)
        }
    }

    /// Starts again what the policy stopped. A download still in the middle of stopping is looked at again shortly.
    private func resumePolicyPaused(attempts: Int) {
        guard networkHold == nil else { return }
        var stillStopping = false
        for id in policyPaused {
            guard let record = ledger.record(id) else { policyPaused.remove(id); continue }
            switch record.state {
            case .paused where interrupted[id] != nil: policyPaused.remove(id); resume(id)
            case .pausing, .running: stillStopping = record.state == .pausing || stillStopping; if record.state == .running { policyPaused.remove(id) }
            default: policyPaused.remove(id)            // the person acted on it (cancelled, removed, resumed it themselves): not ours any more
            }
        }
        if stillStopping, attempts > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.resumePolicyPaused(attempts: attempts - 1)
            }
        }
    }
}

extension DownloadCoordinator {
    /// The Keychain is read once per profile and kept in memory, not on every edit of a settings field. `forgetProxyPasswordCache` after the password changes.
    func cachedProxyPassword() -> String? {
        if let cached = proxyPasswordCache, cached.profile == profileName { return cached.value }
        let value = proxyCredentials.password(profile: profileName)
        proxyPasswordCache = (profileName, value)
        return value
    }

    func forgetProxyPasswordCache() { proxyPasswordCache = nil }
}

extension DownloadCoordinator {
    /// Applies the peer-to-peer settings: the number of torrents and peers, and the speed limits that are enforced where peer data is read and sent.
    func applyTorrentSettings() {
        let s = torrentSettings.normalized()
        TorrentSlots.shared.setLimit(s.maxActiveTorrents)
        PeerBudget.shared.setLimit(s.maxPeersTotal)
        // The limit belongs to this profile's tasks (the scheduler tags every task with `ownerID`); set on the default owner it would govern nobody.
        TorrentBandwidth.download.setOverallLimit(s.downloadLimit, owner: ownerID)
        TorrentBandwidth.upload.setOverallLimit(s.uploadLimit, owner: ownerID)
        if s.enabled, s.seedingMode != .off { torrents.restoreSeeding() }          // finished torrents the person allowed to be shared carry on after a relaunch
        if !s.enabled, torrentsStarted { torrents.stopAllBecauseDisabled() } else if torrentsStarted { torrents.settingsChanged() }
        scheduler.pump()
    }
}

extension DownloadCoordinator {
    /// Applies the eD2k settings: how many downloads and connections, and the speed limit held where data is read.
    func applyED2KSettings() {
        let s = ed2kSettings.normalized()
        ED2KSlots.shared.setLimit(s.maxActiveDownloads)
        ED2KBudget.peers.setLimit(s.maxConnectionsTotal)
        ED2KBandwidth.download.setOverallLimit(s.downloadLimit, owner: ownerID)
        if !s.enabled, ed2kStarted { ed2k.stopAllBecauseDisabled() }
        scheduler.pump()
    }
}
