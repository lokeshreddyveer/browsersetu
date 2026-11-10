import SwiftUI

/// Speed, connections, proxy and network conditions for downloads Browser Setu makes itself. Sits inside the existing Downloads settings; nothing here applies to web pages.
struct DownloadNetworkSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var password = ""
    @State private var limitText = ""
    @State private var unit = Unit.mb

    enum Unit: String, CaseIterable, Identifiable {
        case kb = "KB/s", mb = "MB/s"
        var id: String { rawValue }
        var bytes: Double { self == .kb ? 1024 : 1024 * 1024 }
    }

    private var s: DownloadNetworkSettings { model.downloadNetwork }

    var body: some View {
        Section("Speed and network") {
            Picker("Preset", selection: Binding(get: { s.preset }, set: { model.downloadNetwork = s.applying($0); syncLimitFields() })) {
                ForEach(DownloadNetworkSettings.Preset.allCases) { Text($0.title).tag($0) }
            }.settingsNoted(s.preset.detail + " A preset changes only speed and connection numbers, never the proxy or the network choices below.")

            Toggle("Limit total download speed", isOn: Binding(get: { s.overallLimit != nil }, set: { on in
                model.downloadNetwork.overallLimit = on ? max(BandwidthController.minimumRate, Int64((Double(limitText) ?? 1) * unit.bytes)) : nil
                if on, limitText.isEmpty { limitText = "1"; unit = .mb; model.downloadNetwork.overallLimit = 1 << 20 }
            }))
            if s.overallLimit != nil {
                HStack {
                    TextField("Speed", text: $limitText).frame(width: 90).onSubmit(commitLimit).onChange(of: limitText) { _, _ in commitLimit() }
                    Picker("Unit", selection: $unit) { ForEach(Unit.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        .onChange(of: unit) { _, _ in commitLimit() }
                }
            }
            Text("Applies to downloads Browser Setu makes itself, shared between them, and to a file the website lets it fetch in parts. A download the system fetches as one piece, or one started from a web page, cannot be slowed; the download's details say so. You can also set a limit for one download there.")
                .settingsNote()

            Stepper("Connections to one website: \(s.perHostConnections)", value: bind(\.perHostConnections), in: DownloadNetworkSettings.connectionRange)
            Stepper("Pieces per big file: \(s.workersPerDownload)", value: bind(\.workersPerDownload), in: DownloadNetworkSettings.connectionRange)
                .settingsNoted("More is not always faster. Four is a good balance; a limit applies to all pieces of a file together.")
            Stepper("Wait for a website: \(s.requestTimeout) s", value: bind(\.requestTimeout), in: DownloadNetworkSettings.timeoutRange, step: 5)
            Stepper("Try again by itself: \(s.maxAutomaticRetries) time\(s.maxAutomaticRetries == 1 ? "" : "s")", value: bind(\.maxAutomaticRetries), in: DownloadNetworkSettings.retryRange)

            Picker("Adapt to", selection: bind(\.adaptiveMode)) {
                ForEach(AdaptiveMode.allCases) { Text($0.title).tag($0) }
            }.settingsNoted(s.adaptiveMode.detail + " It can only slow downloads, never go past your own limit, and it cannot see other apps' traffic: it reacts to this app's own errors, page loads and the Mac's power state.")
            if s.adaptiveMode.isAdaptive {
                Stepper("Browser counts as busy for \(s.browserGraceSeconds) s after a page loads", value: bind(\.browserGraceSeconds), in: DownloadNetworkSettings.graceRange)
                let snap = model.downloads.adaptive.snapshot
                VStack(alignment: .leading, spacing: 2) {
                    if let ceiling = snap.rateCeiling { Text("Right now: held to about \(DownloadStats.bytes(ceiling))/s while the browser is busy").font(.caption) }
                    if let workers = snap.workerCeiling { Text("Right now: at most \(workers) connection\(workers == 1 ? "" : "s") per download").font(.caption) }
                    if snap.rateCeiling == nil && snap.workerCeiling == nil { Text("Right now: no adaptive limit in effect").font(.caption).foregroundStyle(.secondary) }
                    if let note = snap.note { Text("Last change: \(note)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button("Reset Speed and Connection Settings") {
                model.downloadNetwork = s.resettingSpeedAndConnections(); syncLimitFields()
            }.settingsNoted("Puts speed, connections, waiting, retries and the adaptive choice back to their defaults. Your proxy and network choices stay.")

            Toggle("Wait when there is no connection", isOn: bind(\.waitForConnectivity))
            Toggle("Pause on a metered connection", isOn: bind(\.pauseOnExpensive))
            Toggle("Pause in Low Data Mode", isOn: bind(\.respectLowDataMode))
            if let hold = model.downloads.networkHold { Label(hold.explanation, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange) }
            Text("Downloads you paused yourself stay paused when the connection is suitable again. Browser Setu only changes its own downloads, never your Mac's network settings.").settingsNote()

            Picker("Proxy", selection: Binding(get: { s.proxy.mode }, set: { model.downloadNetwork.proxy.mode = $0 })) {
                Text("Use my Mac's settings").tag(DownloadNetworkSettings.Proxy.Mode.system)
                Text("No proxy").tag(DownloadNetworkSettings.Proxy.Mode.direct)
                Text("HTTP proxy").tag(DownloadNetworkSettings.Proxy.Mode.http)
                Text("HTTPS proxy").tag(DownloadNetworkSettings.Proxy.Mode.https)
                Text("SOCKS5 proxy").tag(DownloadNetworkSettings.Proxy.Mode.socks5)
            }
            if [.http, .https, .socks5].contains(s.proxy.mode) {
                TextField("Address", text: Binding(get: { s.proxy.host }, set: { model.downloadNetwork.proxy.host = $0 })).autocorrectionDisabled()
                TextField("Port", value: Binding(get: { s.proxy.port }, set: { model.downloadNetwork.proxy.port = $0 }), format: .number.grouping(.never))
                TextField("User name (if it needs one)", text: Binding(get: { s.proxy.username }, set: { model.downloadNetwork.proxy.username = $0 })).autocorrectionDisabled()
                if !s.proxy.username.isEmpty {
                    SecureField(model.hasProxyPassword ? "Password (saved in the Keychain)" : "Password", text: $password)
                        .onSubmit { model.setProxyPassword(password); password = "" }
                    Button("Save Password") { model.setProxyPassword(password); password = "" }.disabled(password.isEmpty)
                }
                if let problem = DownloadProxy.problem(s.proxy) { Text(problem.localizedDescription).font(.caption).foregroundStyle(.orange) }
            }
            Text(DownloadProxy.summary(s.proxy) + " This is only for downloads Browser Setu makes itself; web pages use the browser's own network settings. If the proxy cannot be reached the download fails: it is never sent around it. On this Mac the system connects to 127.0.0.1 directly even when a proxy is set. Downloads that are not your own are never sent through a proxy.")
                .settingsNote()
        }
        .onAppear(perform: syncLimitFields)
    }

    private func bind<T>(_ keyPath: WritableKeyPath<DownloadNetworkSettings, T>) -> Binding<T> {
        Binding(get: { model.downloadNetwork[keyPath: keyPath] }, set: { model.downloadNetwork[keyPath: keyPath] = $0 })
    }

    private func commitLimit() {
        guard s.overallLimit != nil, let value = Double(limitText.replacingOccurrences(of: ",", with: ".")), value > 0 else { return }
        let bytes = Int64(min(value * unit.bytes, Double(DownloadNetworkSettings.maximumLimit)))
        if model.downloadNetwork.overallLimit != bytes { model.downloadNetwork.overallLimit = bytes }
    }

    private func syncLimitFields() {
        guard let limit = s.overallLimit else { return }
        unit = limit >= 1 << 20 ? .mb : .kb
        let v = Double(limit) / unit.bytes
        limitText = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
