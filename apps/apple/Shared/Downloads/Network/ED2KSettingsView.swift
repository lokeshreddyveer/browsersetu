import SwiftUI

/// eD2k downloads: off until the person turns them on; the servers asked for sources are only the ones listed here.
struct ED2KSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var serverText = ""
    private var s: ED2KSettings { model.ed2kSettings }

    var body: some View {
        Section("eD2k links") {
            Toggle("Allow eD2k downloads", isOn: Binding(get: { s.enabled }, set: { on in
                if !on { model.ed2kSettings.enabled = false; return }
                Task { @MainActor in
                    let pressed = await Dialogs.choose(title: "Turn on eD2k downloads?",
                                                       message: "The people who share a file, and the eD2k servers you list, can see your network address. Browser Setu opens no port for incoming connections and shares nothing. Only download files you are allowed to have.",
                                                       buttons: ["Turn On", "Cancel"])
                    if pressed == 0 { model.ed2kSettings.enabled = true }
                }
            }))
            .settingsNoted("Off by default. Pasting a link, or looking at it here, contacts nobody; a server is contacted only when you start a download.")
            if s.enabled {
                TextField("Server to ask for sources, such as 203.0.113.5:4661", text: $serverText).autocorrectionDisabled().onSubmit(addServer)
                Button("Add Server", action: addServer).disabled(ED2KSettings.parseServer(serverText) == nil || s.servers.count >= ED2KSettings.maxServers)
                if !serverText.isEmpty, ED2KSettings.parseServer(serverText) == nil { Text("Use a public IPv4 address and a port, for example 203.0.113.5:4661. Names and local addresses are not accepted.").font(.caption).foregroundStyle(.orange) }
                ForEach(s.servers, id: \.self) { server in
                    HStack { Text(server).font(.system(.body, design: .monospaced)); Spacer(); Button("Remove") { model.ed2kSettings.servers.removeAll { $0 == server } }.buttonStyle(.borderless) }
                }
                Stepper("Downloads at a time: \(s.maxActiveDownloads)", value: bind(\.maxActiveDownloads), in: ED2KSettings.activeRange)
                Stepper("Sources per download: \(s.maxSourcesPerDownload)", value: bind(\.maxSourcesPerDownload), in: ED2KSettings.sourcesRange)
                Stepper("Connections in all: \(s.maxConnectionsTotal)", value: bind(\.maxConnectionsTotal), in: ED2KSettings.totalRange, step: 5)
                Picker("Download speed", selection: Binding(get: { s.downloadLimit }, set: { model.ed2kSettings.downloadLimit = $0 })) {
                    ForEach([("No limit", nil), ("256 KB/s", 256 << 10), ("512 KB/s", 512 << 10), ("1 MB/s", 1 << 20), ("2 MB/s", 2 << 20), ("5 MB/s", 5 << 20)] as [(String, Int64?)], id: \.0) { Text($0.0).tag($0.1) }
                }
                Text("Supported: eD2k file links, server login and source requests, downloading and checking each part. Not supported: Kad, obfuscated or encrypted peers, compressed parts, uploading, and sources you cannot reach directly (low ID). Links to servers and server lists are recognised but never fetched. A proxy chosen under Speed and network is used for servers and sources; if it cannot be used nothing is connected directly. The speed limit slows the connections themselves.")
                    .settingsNote()
            }
        }
    }

    private func bind<T>(_ k: WritableKeyPath<ED2KSettings, T>) -> Binding<T> { Binding(get: { model.ed2kSettings[keyPath: k] }, set: { model.ed2kSettings[keyPath: k] = $0 }) }
    private func addServer() {
        guard let a = ED2KSettings.parseServer(serverText), s.servers.count < ED2KSettings.maxServers else { return }
        let text = "\(a.host):\(a.port)"
        if !model.ed2kSettings.servers.contains(text) { model.ed2kSettings.servers.append(text) }
        serverText = ""
    }
}
