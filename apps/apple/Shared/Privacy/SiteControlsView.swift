import SwiftUI

/// Everything this browser can switch for the one website in front, in one place: protection, pop-ups, autoplay, fingerprint noise,
/// JavaScript, video speed and keeping the tab awake. Each switch is the same setting Settings holds, only for this site.
struct SiteControlsView: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var privacy: PrivacyController

    private var host: String? { model.active?.url?.host }
    private var site: String { host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "this site" }
    private var key: String? { FaviconStore.key(forHost: host) }
    @State private var network = PageNetworkReport()
    @State private var otherSiteCookies = 0
    @State private var loaded = false

    /// What has been turned off for this site, in words.
    private var exceptions: [String] {
        var list: [String] = []
        if privacy.configuration.isException(host: host) { list.append("blocking") }
        if let h = host?.lowercased(), model.popupAllowedHosts.contains(h) { list.append("pop-up blocking") }
        if let k = key, model.autoplayExceptions.contains(k) { list.append("autoplay blocking") }
        if let k = key, model.fingerprintExceptions.contains(k) { list.append("fingerprint noise") }
        if !model.scriptsAllowed(forHost: host) { list.append("JavaScript off") }
        return list
    }

    private func refresh() async {
        guard let tab = model.active, !tab.isBlank else { loaded = true; return }
        network = await tab.engine.pageNetwork()
        if let h = host {
            let report = await model.siteReport(host: h)
            otherSiteCookies = report.thirdPartyCookies.values.reduce(0, +)
        }
        loaded = true
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Connection") {
                    Label(model.active?.isSecure == true ? "Encrypted (HTTPS)" : "Not encrypted", systemImage: model.active?.isSecure == true ? "lock.fill" : "lock.open")
                        .foregroundStyle(model.active?.isSecure == true ? Color.green : Color.orange)
                }
                LabeledContent("Blocked requests", value: loaded ? "\(network.blockedURLs.count)" : "…")
                if network.kinds.ads + network.kinds.trackers > 0 {
                    LabeledContent("Ads (estimate)", value: "\(network.kinds.ads)")
                    LabeledContent("Trackers (estimate)", value: "\(network.kinds.trackers)")
                }
                LabeledContent("Other sites contacted", value: loaded ? "\(network.thirdPartyHosts.count)" : "…")
                LabeledContent("Cookies kept from other sites", value: loaded ? "\(otherSiteCookies)" : "…")
                LabeledContent("Cross-site tracking", value: "Restricted by WebKit")
                DisclosureGroup("Blocked requests by site") {
                    if network.blockedByHost.isEmpty { Text("None seen on this page.").foregroundStyle(.secondary) }
                    ForEach(network.blockedByHost.prefix(25), id: \.host) { LabeledContent($0.host, value: "\($0.count)") }
                }
                DisclosureGroup("Other sites this page loaded from") {
                    if network.thirdPartyHosts.isEmpty { Text("None seen on this page.").foregroundStyle(.secondary) }
                    ForEach(network.thirdPartyHosts.prefix(60), id: \.self) { Text($0) }
                }
                if !exceptions.isEmpty {
                    LabeledContent("Exceptions on this site", value: exceptions.joined(separator: ", "))
                }
            } header: { Text("On \(site) right now") } footer: {
                Text("Counts come from the page itself: blocked requests are the ones that never reached the network. WebKit does not say which list blocked a request, so ads and trackers are a guess from the names. Refresh by reopening this panel.")
            }
            .task(id: model.active?.id) { await refresh() }
            Section {
                Toggle("Block ads and trackers", isOn: Binding(
                    get: { !privacy.configuration.isException(host: host) },
                    set: { _ in privacy.toggleSite(host: host) }))
                Toggle("Block pop-ups that open without a click", isOn: Binding(
                    get: { !(host.map { model.popupAllowedHosts.contains($0.lowercased()) } ?? false) },
                    set: { on in
                        guard let h = host?.lowercased() else { return }
                        if on { model.popupAllowedHosts.remove(h) } else { model.popupAllowedHosts.insert(h) }
                    }))
                    .disabled(!model.blockPopups)
                Toggle("Stop video and sound starting by themselves", isOn: Binding(
                    get: { !(key.map { model.autoplayExceptions.contains($0) } ?? false) },
                    set: { on in model.setAutoplayException(host: host, allowed: !on) }))
                    .disabled(!model.blockAutoplay)
                Toggle("Randomize canvas and audio details", isOn: Binding(
                    get: { !(key.map { model.fingerprintExceptions.contains($0) } ?? false) },
                    set: { on in model.setFingerprintException(host: host, allowed: !on) }))
                    .disabled(!model.randomizeFingerprint)
            } header: { Text("Protection on \(site)") } footer: {
                if !model.blockPopups || !model.blockAutoplay || !model.randomizeFingerprint {
                    Text("A greyed-out switch is off for every site. Turn it on in the protections list first.")
                }
            }
            Section("Page") {
                Toggle("Run JavaScript", isOn: Binding(
                    get: { model.scriptsAllowed(forHost: host) },
                    set: { on in model.setScripts(host: host, allowed: on); model.active?.reload() }))
                Picker("Video speed", selection: Binding(get: { model.activeVideoSpeed ?? 1 }, set: { model.setVideoSpeed($0) })) {
                    ForEach(VideoControls.speeds, id: \.self) { Text(VideoControls.label($0)).tag($0) }
                }
                Toggle("Keep this site's tab awake", isOn: Binding(
                    get: { model.neverSleeps(host: host) },
                    set: { model.setNeverSleeps(host: host, $0) }))
            }
            Section {
                Text("These switches apply only to \(site). A change to JavaScript reloads the page.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
