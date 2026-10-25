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
    @State private var grants: [PermissionGrant] = []
    /// The open-in-private rule lives in the workbench, which this view does not watch; this makes the switch redraw after a change.
    @State private var ruleRevision = 0

    private var finding: LookalikeCheck.Finding? { host.flatMap { LookalikeCheck.check(host: $0) } }
    private var granted: [PermissionGrant] {
        grants.filter { $0.decision == .allow && URL(string: $0.origin)?.host?.lowercased() == host?.lowercased() }
    }
    private var score: SiteScore {
        SiteScore.score(secure: model.active?.isSecure == true, thirdParties: network.thirdPartyHosts.count,
                        blocked: network.blockedURLs.count, permissionsGranted: granted.count, lookalike: finding)
    }

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
        grants = (try? model.core.listPermissions()) ?? []
        loaded = true
    }

    private static let zoomSteps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    private var zoomChoice: Binding<Double> {
        Binding<Double>(
            get: { model.siteZoomFactor(forHost: host) ?? 1 },
            set: { value in
                model.rememberZoom(value, forHost: host)
                model.active?.applySavedZoom()
            })
    }

    private var appearanceChoice: Binding<AppearanceMode> {
        Binding<AppearanceMode>(
            get: { model.siteHasAppearance(host) ? model.effectiveWebsiteAppearance(host: host) : AppearanceMode.system },
            set: { value in model.setSiteAppearance(host, value) })
    }

    private var privateRule: Binding<Bool> {
        Binding<Bool>(
            get: { _ = ruleRevision; return model.workbench.siteRules.contains { $0.action == .privateTab && $0.matches(host: host) } },
            set: { on in
                guard let h = host?.lowercased() else { return }
                var rules: [SiteOpenRule] = []
                for rule in model.workbench.siteRules {
                    let isThisOne: Bool = rule.action == SiteOpenRule.Action.privateTab && rule.host.lowercased() == h
                    if !isThisOne { rules.append(rule) }
                }
                if on { rules.append(SiteOpenRule(host: h, action: SiteOpenRule.Action.privateTab)) }
                model.workbench.setSiteRules(rules)
                ruleRevision += 1
            })
    }

    private var lookSection: some View {
        Section {
                Picker("Zoom", selection: zoomChoice) {
                    ForEach(Self.zoomSteps, id: \.self) { step in Text("\(Int(step * 100))%").tag(step) }
                }
                Picker("Appearance", selection: appearanceChoice) {
                    Text("Same as other sites").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                Toggle("Always open this site in a private tab", isOn: privateRule)
                    } header: { Text("Look on \(site)") }
    }

    @ViewBuilder private var permissionsSection: some View {
            if !granted.isEmpty {
                Section {
                    ForEach(granted, id: \.self) { grant in
                        HStack {
                            Text("\(String(describing: grant.kind).capitalized) allowed")
                            Spacer()
                            Button("Take Back") {
                                try? model.core.rememberPermission(origin: grant.origin, kind: grant.kind, decision: .prompt)
                                grants = (try? model.core.listPermissions()) ?? []
                            }.buttonStyle(.borderless)
                        }
                    }
                } header: { Text("Allowed on \(site)") } footer: { Text("Taking a permission back means the site has to ask again.") }
            }
    }

    private func gradeColor(_ grade: String) -> Color {
        switch grade { case "A": .green; case "B": .mint; case "C": .yellow; case "D": .orange; default: .red }
    }

    var body: some View {
        Form {
            if loaded, model.active?.isBlank == false {
                Section {
                    HStack(spacing: 14) {
                        Text(score.grade).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .frame(width: 60, height: 60).background(Circle().fill(gradeColor(score.grade).gradient))
                            .contentTransition(.numericText())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Privacy grade for \(site)").font(.headline)
                            Text(score.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(score.reasons) { reason in
                        Label(reason.text, systemImage: reason.good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(reason.good ? Color.primary : Color.orange).font(.callout)
                    }
                } footer: { Text("Worked out on this device from what the page just did. Nothing is sent anywhere.") }
                .transition(.opacity)
            }
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
            SecurityHeadersSection(host: host)
            lookSection
            permissionsSection
            Section {
                Text("These switches apply only to \(site). A change to JavaScript reloads the page.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
