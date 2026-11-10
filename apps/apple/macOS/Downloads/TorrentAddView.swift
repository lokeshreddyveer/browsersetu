import SwiftUI
import AppKit

/// Step two of adding a torrent or a magnet link: what it is, which files, where it goes, and what the person is agreeing to. Nothing is sent over the network by looking at this,
/// except when the person asks for a magnet link's details (that contacts its trackers and peers).
@MainActor
final class TorrentAddModel: ObservableObject {
    let coordinator: DownloadCoordinator
    let magnet: MagnetLink?
    @Published var meta: TorrentMetainfo?
    @Published var inspection: TorrentInspection?
    /// The files, their priorities and the order. Skip means not downloaded; a torrent is never started with every file skipped.
    @Published var selection = TorrentSelection(priorities: [:])
    /// Files chosen, for callers that only need the set.
    var selected: Set<Int> {
        get { meta.map { selection.selected(in: $0) } ?? [] }
        set { if let meta { selection = TorrentSelection.only(newValue, in: meta) } }
    }
    /// Something about the choice the person should read (a magnet link's file numbers that do not exist, for example).
    @Published var selectionNote: String?
    /// The person chose to fetch from the torrent\'s web seeds only: no tracker, DHT or peer is contacted, and peer-to-peer need not be on.
    @Published var httpOnly = false
    /// The person approved web seeds that are on their own network (listed in the sheet).
    @Published var allowLocalSeeds = false
    @Published var busy = false
    @Published var problem: String?
    /// Where the link came from. A magnet link from a web page is held to the page's limits (see `TorrentRunner.usableTrackers`).
    let origin: DownloadRequestOrigin

    init(coordinator: DownloadCoordinator, magnet: MagnetLink, origin: DownloadRequestOrigin = .user) { self.coordinator = coordinator; self.magnet = magnet; self.origin = origin }

    init(coordinator: DownloadCoordinator, torrentData: Data) throws {
        self.coordinator = coordinator; magnet = nil; origin = .user
        let look = try coordinator.torrents.inspect(torrentFile: torrentData)
        meta = look.meta; inspection = look; selection = TorrentSelection.all(look.meta)
    }

    var enabled: Bool { coordinator.torrentSettings.enabled }

    /// Turns peer-to-peer on from the link's own preview, after the same question Settings asks, and only if the person agrees. Nothing is contacted by this; Get Details still has to be pressed.
    /// Whether the public DHT is on (it is off until the person allows it).
    var dhtOn: Bool { coordinator.torrentSettings.dhtEnabled }
    /// The same question Settings asks before the DHT is used, asked here where the lookup failed.
    func turnOnDHT() {
        Task { @MainActor in
            let pressed = await Dialogs.choose(title: TorrentSettings.dhtConsentTitle, message: TorrentSettings.dhtConsentMessage, buttons: ["Turn On", "Cancel"])
            if pressed == 0 { coordinator.torrentSettings.dhtEnabled = true; objectWillChange.send() }
        }
    }
    func turnOnPeerToPeer() {
        Task { @MainActor in
            let pressed = await Dialogs.choose(title: TorrentSettings.consentTitle, message: TorrentSettings.consentMessage, buttons: ["Turn On", "Cancel"])
            if pressed == 0 { coordinator.torrentSettings.enabled = true; objectWillChange.send() }
        }
    }
    var selectedBytes: Int64 { meta.map { TorrentFileTree.chosenBytes(selection, meta: $0) } ?? 0 }
    /// Web seeds this torrent (or the magnet link) names, shown before the download so the person knows an HTTP server will be contacted.
    var webSeedsNotice: String {
        let hosts = webSeedHosts
        var text = "Web seeds: " + hosts.prefix(3).joined(separator: ", ")
        if hosts.count > 3 { text += " and \(hosts.count - 3) more" }
        text += ". Browser Setu may also fetch pieces from these servers over HTTP."
        return text
    }
    var localSeedsLabel: String {
        let hosts = localWebSeedHosts.prefix(3).joined(separator: ", ")
        return "Allow web seeds on my local network (" + hosts + ")"
    }
    /// "3 files, 1.2 GB · chosen: 800 MB": padding entries (BEP 47) are not files the person sees, and their bytes are not part of the size.
    var summaryLine: String {
        guard let meta else { return "" }
        let n = meta.visibleFiles.count
        let word = n == 1 ? "file" : "files"
        return String(n) + " " + word + ", " + DownloadStats.bytes(meta.contentLength) + " · chosen: " + DownloadStats.bytes(selectedBytes) + " · saved to your Downloads folder"
    }
    var hasWebSeeds: Bool { meta.map { !WebSeedMapping.sources(meta: $0, magnetSeeds: magnet?.webSeeds ?? []).isEmpty } ?? false }
    /// Web seeds on the local network: used only if the person approves them here (nothing asks in the background later).
    var localWebSeedHosts: [String] {
        guard let meta else { return [] }
        return Array(Set(WebSeedMapping.sources(meta: meta, magnetSeeds: magnet?.webSeeds ?? []).filter { LocalTrackerPermission.isLocal($0.url) }.map(\.displayName))).sorted()
    }
    /// Whether the torrent can be started now: peer-to-peer is on, or the person chose web seeds only.
    var canStart: Bool { enabled || (httpOnly && hasWebSeeds) }
    var webSeedHosts: [String] {
        guard let meta else { return [] }
        return Array(Set(WebSeedMapping.sources(meta: meta, magnetSeeds: magnet?.webSeeds ?? []).map(\.displayName))).sorted()
    }

    /// What the details search is doing, while it runs (nil before and after).
    @Published var lookupStatus: MetadataProbeStatus?

    func getDetails() {
        guard let magnet, !busy else { return }
        busy = true; problem = nil; lookupStatus = nil
        Task {
            do {
                let fetched = try await coordinator.torrents.fetchDetails(of: magnet, origin: origin, progress: { [weak self] status in self?.lookupStatus = status })
                var withTrackers = fetched; if withTrackers.trackers.isEmpty { withTrackers.trackers = TorrentRunner.usableTrackers(magnet.trackers, origin: origin, granted: coordinator.torrents.localTrackerPermission.granted()) }
                meta = withTrackers; inspection = coordinator.torrents.inspection(of: withTrackers)
                // A magnet link may name the files it wants (BEP 53). What it names is checked against the real list; a malformed or impossible choice is explained, and never turns into "everything".
                switch magnet.selectOnly {
                case .indices(let wanted)?: let applied = MagnetSelection.apply(wanted, to: fetched); selection = applied.selection; selectionNote = applied.problem
                case .malformed(let why)?: selection = TorrentSelection.only([], in: fetched); selectionNote = why + " Choose the files you want."
                case nil: selection = TorrentSelection.all(fetched)
                }
            } catch { problem = (error as? LocalizedError)?.errorDescription ?? "The details could not be fetched." }
            busy = false; lookupStatus = nil
        }
    }

    func start(done: @escaping () -> Void) {
        guard let meta, !busy else { return }
        busy = true
        Task {
            do { _ = try await coordinator.torrents.add(meta, selection: selection, origin: origin, magnetSeeds: magnet?.webSeeds ?? [], httpOnly: httpOnly, allowLocalWebSeeds: allowLocalSeeds && !localWebSeedHosts.isEmpty); done() }
            catch { problem = (error as? LocalizedError)?.errorDescription ?? "The download could not be started." }
            busy = false
        }
    }
}

struct TorrentAddView: View {
    @ObservedObject var model: TorrentAddModel
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.meta?.name ?? model.magnet?.displayName ?? "Magnet link").font(.system(size: 13, weight: .semibold)).lineLimit(2).textSelection(.enabled)
            if let meta = model.meta {
                Text(model.summaryLine)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                TorrentFilesView(meta: meta, selection: $model.selection, maxHeight: 230)
                orderPicker
                if let note = model.selectionNote { Text(note).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if !model.webSeedHosts.isEmpty {
                    Label(model.webSeedsNotice, systemImage: "network")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let magnet = model.magnet {
                Text("A magnet link names a torrent but does not describe it. Getting the list of files contacts \(magnet.trackers.isEmpty ? "no tracker (the link names none)" : "the tracker\(magnet.trackers.count == 1 ? "" : "s") it lists") and the peers they return.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let inspection = model.inspection {
                Label(inspection.privacyNotice, systemImage: "eye").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !inspection.trackerHosts.isEmpty { Text("Trackers: " + inspection.trackerHosts.prefix(4).joined(separator: ", ") + (inspection.trackerHosts.count > 4 ? " and \(inspection.trackerHosts.count - 4) more" : "")).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            if model.hasWebSeeds, !model.localWebSeedHosts.isEmpty {
                Toggle(model.localSeedsLabel, isOn: $model.allowLocalSeeds).font(.system(size: 11.5)).toggleStyle(.checkbox)
                    .help("This torrent names servers on your own network. They are contacted only if you allow it here.")
            }
            if !model.enabled && model.meta != nil && model.hasWebSeeds {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Download from the web seeds only (no peer-to-peer)", isOn: $model.httpOnly).font(.system(size: 11.5)).toggleStyle(.checkbox)
                    Text("Peer-to-peer is off. This torrent names web seeds (ordinary HTTP servers), so it can be fetched from them alone: no tracker, DHT or peer is contacted and nothing is shared. The servers see your network address. Every piece is still checked against the torrent.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.canStart {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Peer-to-peer downloads are off. Turn them on in Settings → Downloads to continue.", systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Turn On Peer-to-Peer…") { model.turnOnPeerToPeer() }.buttonStyle(.link).font(.system(size: 11.5))
                        Button("Open Settings → Downloads") { SettingsRouter.open(.downloads) }.buttonStyle(.link).font(.system(size: 11.5))
                    }
                }
            }
            if let problem = model.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if model.magnet != nil, model.meta == nil, !model.dhtOn { Button("Turn On the Public DHT…") { model.turnOnDHT() }.buttonStyle(.link).font(.system(size: 11.5)) }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small); if model.meta == nil { Text(model.lookupStatus.map { "Looking for peers… " + $0.summary } ?? "Looking for peers…").font(.system(size: 11.5)).foregroundStyle(.secondary) } }
                Spacer()
                Button("Cancel", action: done)
                if model.meta == nil {
                    Button("Get Details", action: model.getDetails).buttonStyle(.borderedProminent).disabled(!model.enabled || model.busy)
                } else {
                    Button("Download", action: { model.start(done: done) }).buttonStyle(.borderedProminent).disabled(!model.canStart || model.busy || model.selected.isEmpty).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14).frame(width: 460)
    }

    /// How pieces are taken. "In order" and "Streaming" help a file be used while it arrives, and cost the swarm some efficiency.
    @ViewBuilder private var orderPicker: some View {
        HStack(spacing: 8) {
            Text("Download order").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Picker("Download order", selection: $model.selection.mode) { ForEach(ScheduleMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
        }
        if model.selection.mode != .automatic {
            Text(model.selection.mode == .sequential ? "Pieces are taken from the start of the files. This can make the download slower for everyone sharing it." : "Pieces near the playback position are taken first. This can make the download slower for everyone sharing it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
