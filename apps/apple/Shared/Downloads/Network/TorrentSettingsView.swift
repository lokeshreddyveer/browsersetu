import SwiftUI

/// Peer-to-peer downloads: off until the person turns them on, with what that means said before they do.
struct TorrentSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    private var s: TorrentSettings { model.torrentSettings }
    private static let speeds: [(String, Int64?)] = [("No limit", nil), ("256 KB/s", 256 << 10), ("512 KB/s", 512 << 10), ("1 MB/s", 1 << 20), ("2 MB/s", 2 << 20), ("5 MB/s", 5 << 20), ("10 MB/s", 10 << 20)]

    var body: some View {
        Section("Torrents (peer-to-peer)") {
            Toggle("Allow torrent and magnet downloads", isOn: Binding(get: { s.enabled }, set: { on in
                if !on { model.torrentSettings.enabled = false; return }
                Task { @MainActor in
                    let pressed = await Dialogs.choose(title: TorrentSettings.consentTitle, message: TorrentSettings.consentMessage, buttons: ["Turn On", "Cancel"])
                    if pressed == 0 { model.torrentSettings.enabled = true }
                }
            }))
            .settingsNoted("Off by default. Nothing contacts a tracker or a peer until this is on, and looking at a torrent or a magnet link never does.")
            if s.enabled {
                Stepper("Torrents at a time: \(s.maxActiveTorrents)", value: bind(\.maxActiveTorrents), in: TorrentSettings.activeRange)
                Stepper("Connections per torrent: \(s.maxPeersPerTorrent)", value: bind(\.maxPeersPerTorrent), in: TorrentSettings.peersRange)
                Stepper("Connections in all: \(s.maxPeersTotal)", value: bind(\.maxPeersTotal), in: TorrentSettings.totalRange, step: 10)
                Picker("Download speed", selection: bindLimit(\.downloadLimit)) { ForEach(Self.speeds, id: \.0) { Text($0.0).tag($0.1) } }
                Picker("Upload speed", selection: bindLimit(\.uploadLimit)) { ForEach(Self.speeds, id: \.0) { Text($0.0).tag($0.1) } }
                Toggle("Send pieces to other peers while downloading", isOn: bind(\.shareWhileDownloading))
                    .settingsNoted("Peers who get nothing from you tend to send you little. This is not seeding: when a download finishes, sharing stops. Turn it off to only receive.")
                sharingGroup
                Toggle("Find peers on the public DHT", isOn: Binding(get: { s.dhtEnabled }, set: { on in
                    if !on { model.torrentSettings.dhtEnabled = false; return }
                    Task { @MainActor in
                        let pressed = await Dialogs.choose(title: TorrentSettings.dhtConsentTitle, message: TorrentSettings.dhtConsentMessage, buttons: ["Turn On", "Cancel"])
                        if pressed == 0 { model.torrentSettings.dhtEnabled = true }
                    }
                }))
                .settingsNoted("Off by default. Lets a magnet link with no tracker find peers, and adds peers for torrents that are not private. Private torrents never use it. Needs “No proxy”: a proxy cannot carry the DHT's UDP.")
                Picker("Peer connections", selection: Binding(get: { s.transport }, set: { model.torrentSettings.transport = $0 })) { ForEach(TransportPreference.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .settingsNoted("Automatic tries TCP and then µTP (a gentler UDP transport). µTP cannot go through a proxy.")
                Picker("Encryption", selection: Binding(get: { s.encryption }, set: { model.torrentSettings.encryption = $0 })) { ForEach(EncryptionPolicy.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .settingsNoted("Scrambles the stream so it does not look like BitTorrent. It is not secure encryption: the other peer sees everything, and it does not make you anonymous. “Require” never falls back to plain.")
                Toggle("Accept incoming connections", isOn: Binding(get: { s.inboundEnabled }, set: { on in
                    if !on { model.torrentSettings.inboundEnabled = false; return }
                    Task { @MainActor in
                        let pressed = await Dialogs.choose(title: TorrentSettings.inboundConsentTitle, message: TorrentSettings.inboundConsentMessage, buttons: ["Turn On", "Cancel"])
                        if pressed == 0 { model.torrentSettings.inboundEnabled = true }
                    }
                }))
                .settingsNoted("Off by default. Lets other peers connect to you, which helps downloads when your router allows it. Needs “No proxy”.")
                if s.inboundEnabled {
                    TextField("Port (blank: chosen for you)", text: Binding(get: { s.listenPort.map(String.init) ?? "" }, set: { model.torrentSettings.listenPort = Int($0).flatMap { (1...65535).contains($0) ? $0 : nil } }))
                    Toggle("Ask my router to open the port (PCP / NAT-PMP / UPnP)", isOn: Binding(get: { s.portMappingEnabled }, set: { on in
                        if !on { model.torrentSettings.portMappingEnabled = false; return }
                        Task { @MainActor in
                            let pressed = await Dialogs.choose(title: TorrentSettings.mappingConsentTitle, message: TorrentSettings.mappingConsentMessage, buttons: ["Turn On", "Cancel"])
                            if pressed == 0 { model.torrentSettings.portMappingEnabled = true }
                        }
                    }))
                    .settingsNoted("Off by default. Sends small requests to your router (PCP, then NAT-PMP, then UPnP) and removes them again when incoming connections stop. Many routers do not answer; the torrent's details say what the router did.")
                }
                Toggle("Exchange peers with other peers (PEX)", isOn: Binding(get: { s.pexEnabled }, set: { model.torrentSettings.pexEnabled = $0 }))
                    .settingsNoted("Peers you are already connected to can tell you about others, and you tell them. Not used for private torrents.")
                Toggle("Find peers on my local network", isOn: Binding(get: { s.localDiscoveryEnabled }, set: { on in
                    if !on { model.torrentSettings.localDiscoveryEnabled = false; return }
                    Task { @MainActor in
                        let pressed = await Dialogs.choose(title: TorrentSettings.lanConsentTitle, message: TorrentSettings.lanConsentMessage, buttons: ["Turn On", "Cancel"])
                        if pressed == 0 { model.torrentSettings.localDiscoveryEnabled = true }
                    }
                }))
                .settingsNoted("Off by default. Listens for other computers on your network that are sharing the same torrent, and allows connections to them. Not used for private torrents. Needs “No proxy”.")
                Text("These limits slow the connections themselves, so they are real limits for torrents. Peers are found through the torrent's trackers, and, if you turn them on, the DHT, peer exchange and your local network. Connections use TCP or µTP as chosen above, by Browser Setu connecting out and, if you allow it, by peers connecting in. A proxy you choose above (HTTP, HTTPS or SOCKS5) is used for peers and trackers, and if it cannot be used nothing is connected directly. “Use my Mac's settings” follows the Mac's proxy for trackers, and while the Mac uses one, peers and UDP trackers are not contacted (they cannot go through it): choose “No proxy” to connect directly. Trackers are told port 0, because nothing listens for incoming connections.")
                    .settingsNote()
                LocalNetworkPermissionRows()
            }
        }
    }

    private static let ratios: [(String, Double?)] = [("No limit", nil), ("0.5", 0.5), ("1.0", 1.0), ("1.5", 1.5), ("2.0", 2.0), ("3.0", 3.0), ("5.0", 5.0)]
    private static let times: [(String, Double?)] = [("No limit", nil), ("1 hour", 3600), ("6 hours", 21_600), ("24 hours", 86_400), ("3 days", 259_200), ("7 days", 604_800)]

    /// Sharing a finished torrent: off until the person says so, with the consequences said first. Each torrent also needs its own start (in its details).
    @ViewBuilder private var sharingGroup: some View {
        Picker("Share finished torrents", selection: Binding(get: { s.seedingMode }, set: { mode in
            if mode == .off || s.seedingMode != .off { model.torrentSettings.seedingMode = mode; return }
            Task { @MainActor in
                let pressed = await Dialogs.choose(title: TorrentSettings.seedingConsentTitle, message: TorrentSettings.seedingConsentMessage, buttons: ["Turn On", "Cancel"])
                if pressed == 0 { model.torrentSettings.seedingMode = mode }
            }
        })) { ForEach(SeedingMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            .settingsNoted("Off by default, and a download finishing never turns it on. Even when on, a torrent is shared only after you start it in its details. Sharing lets other peers see your network address and uses upload data.")
        if s.seedingMode != .off {
            Picker("Stop at share ratio", selection: bindOptional(\.ratioTarget)) { ForEach(Self.ratios, id: \.0) { Text($0.0).tag($0.1) } }
                .settingsNoted("Ratio is what you uploaded divided by the size of the files you chose.")
            Picker("Stop after seeding for", selection: bindOptional(\.seedTimeLimit)) { ForEach(Self.times, id: \.0) { Text($0.0).tag($0.1) } }
            Picker("Seeding upload speed", selection: bindLimit(\.seedUploadLimit)) { ForEach(Self.speeds, id: \.0) { Text($0.0).tag($0.1) } }
                .settingsNoted("Held for each sharing torrent, and never above the overall upload speed.")
            Stepper("Peers uploaded to at once: \(s.maxUploadPeers)", value: bind(\.maxUploadPeers), in: TorrentSettings.uploadPeersRange)
            Toggle("Initial seeding (give out one piece at a time)", isOn: bind(\.initialSeeding))
                .settingsNoted("For the first source of a torrent only: each peer is offered one piece and gets another after it has been passed on, so your upload is not spent sending the same data to everyone. Used only when all of the torrent's files are chosen; it ends by itself when others have complete copies.")
        }
    }

    private func bindOptional(_ k: WritableKeyPath<TorrentSettings, Double?>) -> Binding<Double?> {
        Binding(get: { model.torrentSettings[keyPath: k] }, set: { model.torrentSettings[keyPath: k] = $0 })
    }

    private func bind<T>(_ k: WritableKeyPath<TorrentSettings, T>) -> Binding<T> { Binding(get: { model.torrentSettings[keyPath: k] }, set: { model.torrentSettings[keyPath: k] = $0 }) }
    private func bindLimit(_ k: WritableKeyPath<TorrentSettings, Int64?>) -> Binding<Int64?> {
        Binding(get: { model.torrentSettings[keyPath: k] }, set: { model.torrentSettings[keyPath: k] = $0 })
    }
}

/// The local-network trackers a web page's link was allowed to use ("Remember" in the permission question), each removable. The same store the question writes to; nothing else keeps them.
private struct LocalNetworkPermissionRows: View {
    @State private var destinations: [String] = []
    @State private var peers: Set<String> = []
    private let store = LocalTrackerPermission.shared

    var body: some View {
        Group {
            if destinations.isEmpty {
                Text("No local-network trackers are remembered. A web page's link that names one asks first.").settingsNote()
            } else {
                ForEach(destinations, id: \.self) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key.components(separatedBy: "://").last ?? key)
                            Text(peers.contains(key) ? "Tracker and the computers it lists" : "Tracker only").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { store.revoke(key); reload() }.accessibilityIdentifier("permission-remove")
                    }
                }
                Button("Remove All", role: .destructive) { store.revokeAll(); reload() }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() { destinations = store.rememberedDestinations; peers = store.rememberedPeerDestinations }
}

extension TorrentSettings {
    /// What the person is told before peer-to-peer is turned on, from Settings or from a link's own preview: one text, so both say the same.
    static let inboundConsentTitle = "Accept incoming connections?"
    static let inboundConsentMessage = "Browser Setu will open a port on this Mac so other peers can connect to you. Anyone who knows a torrent you are downloading can try to connect, and the peers you connect to will see your network address either way. Only BitTorrent connections for a torrent that is running are accepted, a limited number at a time, and nothing is shared that you did not choose to download. Your router may still block them. You can turn this off at any time and the port is closed."
    static let mappingConsentTitle = "Ask your router to open the port?"
    static let mappingConsentMessage = "Browser Setu will send small PCP, NAT-PMP and UPnP requests to your router (the gateway of this network) asking it to forward the listening port to this Mac, and will ask it to remove that again when incoming connections stop. This makes this Mac reachable from the internet on that port for BitTorrent. Some routers support none of them, and nothing is claimed to work until a peer actually connects. You can turn this off at any time."
    static let lanConsentTitle = "Find peers on your local network?"
    static let lanConsentMessage = "Other computers on your network can see which torrent you are looking for, and a computer that announces itself there can ask Browser Setu to connect to it, so Browser Setu will connect to computers on your own network that it learns of this way. Nothing is announced for private torrents. A computer on your network is not necessarily trustworthy. You can turn this off at any time, and connections that depended on it end."
    static let dhtConsentTitle = "Find peers on the public DHT?"
    static let dhtConsentMessage = "The DHT is a public network of computers that anyone can join. Your network address and the identifier of each torrent you look up are visible to the nodes you contact. Browser Setu cannot tell whether a magnet link with no details is a private torrent until it has the details, so a lookup for one is made before that is known. Once details show a torrent is private, its DHT peers are dropped and it is never looked up again. You can turn this off at any time."
    static let seedingConsentTitle = "Share finished torrents?"
    static let seedingConsentMessage = "Browser Setu will upload the files of a finished torrent to other peers, only for torrents you start sharing. Peers and trackers can see your network address while you share. It uses your internet data and upload speed, and it reads the files from your disk for as long as it runs. You can set a share ratio, a time limit and an upload speed in Settings, and stop any torrent from its details. Only share files you are allowed to share. Nothing is shared unless you turn this on, a download finishing never turns it on, and turning peer-to-peer off stops it at once."
    static let consentTitle = "Turn on peer-to-peer downloads?"
    static let consentMessage = "Other people sharing a torrent, and the torrent's trackers, can see your network address. Browser Setu opens no port for incoming connections unless you turn that on separately, and shares nothing once a download is finished unless you turn that on separately. Only use torrents you are allowed to download."
}
