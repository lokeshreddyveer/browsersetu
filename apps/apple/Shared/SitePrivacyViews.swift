import SwiftUI

/// One screen for the page in front: what it has stored, what it is allowed, how it identifies the browser, how safe its connection looks, and the ways to clear it.
struct SitePrivacyView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var report: SiteReport?
    @State private var security: SecurityReport?
    @State private var checking = false
    @State private var confirmForget = false
    @State private var ruleHosts = ""
    @State private var ruleTrigger = SiteDeleteRule.Trigger.lastTabCloses
    @State private var ruleScope = SiteDeleteRule.Scope.data

    private var host: String? { model.active?.url?.host }
    private var key: String? { FaviconStore.key(forHost: host) }

    var body: some View {
        List {
            if let host {
                Section("What \(TabOrganizing.siteName(forHost: host)) has here") { reportRows }
                Section("Safety of this page") { securityRows }
                Section("Identity, scripts and sleep") { identityRows(host: host) }
                Section {
                    Button("Forget This Site Completely…", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("Removes its cookies, stored data and cache (in every container too), its history, saved permissions, saved sign-ins, notes, style and zoom. Bookmarks are kept.")
                }
            } else {
                Section { Text("Open a page to see what its website has stored.").foregroundStyle(.secondary) }
            }
            rulesSection
            PermissionActivitySection()
        }
        .task(id: host) { await refresh() }
        .confirmationDialog("Forget \(host.map(TabOrganizing.siteName(forHost:)) ?? "this site") completely?", isPresented: $confirmForget) {
            Button("Forget Everything", role: .destructive) { Task { await model.forgetActiveSiteCompletely(); await refresh() } }
        } message: { Text("This cannot be undone. The page reloads without anything it stored.") }
        .accessibilityIdentifier("site-privacy")
    }

    @ViewBuilder private var reportRows: some View {
        if let report {
            if report.isEmpty { Text("Nothing is stored for this site.").foregroundStyle(.secondary) }
            LabeledContent("Its own cookies", value: "\(report.firstPartyCookies)")
            if !report.thirdPartyCookies.isEmpty {
                DisclosureGroup("Cookies from other sites (\(report.thirdPartyCookies.values.reduce(0, +)))") {
                    ForEach(report.thirdPartyCookies.sorted { $0.value > $1.value }, id: \.key) { LabeledContent($0.key, value: "\($0.value)") }
                }
            }
            LabeledContent("Stored data", value: report.storage.isEmpty ? "none" : report.storage.joined(separator: ", "))
            LabeledContent("Saved decisions", value: report.permissions.isEmpty ? "none" : report.permissions.joined(separator: ", "))
            LabeledContent("Saved sign-ins", value: "\(report.savedSignIns)")
            LabeledContent("History entries", value: "\(report.historyEntries)")
            LabeledContent("Your settings for it", value: report.settings.isEmpty ? "none" : report.settings.joined(separator: ", "))
        } else { ProgressView().controlSize(.small) }
    }

    @ViewBuilder private var securityRows: some View {
        Button(checking ? "Checking…" : "Check This Page") { Task { await runSecurityCheck() } }.disabled(checking)
        if let security {
            ForEach(Array(security.findings.enumerated()), id: \.offset) { _, finding in
                Label(finding.text, systemImage: finding.severity == .danger ? "exclamationmark.octagon.fill" : (finding.severity == .caution ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"))
                    .foregroundStyle(finding.severity == .danger ? Color.red : (finding.severity == .caution ? Color.orange : Color.green))
            }
            if let identity = model.active?.identity {
                VStack(alignment: .leading, spacing: 2) {
                    Label(identity.headline, systemImage: identity.isVerified ? "checkmark.seal.fill" : "lock.fill").foregroundStyle(identity.isVerified ? Color.green : Color.secondary)
                    Text(identity.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Connection", value: security.isHTTPS ? (security.transport.isEmpty ? "encrypted" : "encrypted (\(security.transport))") : "not encrypted")
            LabeledContent("Redirects on the way", value: "\(security.redirects)")
            ForEach(Array(security.certificates.enumerated()), id: \.offset) { index, cert in
                VStack(alignment: .leading, spacing: 2) {
                    Text(index == 0 ? "Site certificate: \(cert.subject)" : "Signed by: \(cert.subject)").font(.callout)
                    Text("Issued by \(cert.issuer)" + (cert.expires.map { " · expires " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !security.mixedContent.isEmpty {
                DisclosureGroup("Loaded without encryption (\(security.mixedContent.count))") { ForEach(security.mixedContent, id: \.self) { Text($0).font(.caption).lineLimit(2) } }
            }
        }
    }

    @ViewBuilder private func identityRows(host: String) -> some View {
        Picker("Identify this site's visits as", selection: Binding(get: { key.flatMap { model.siteUserAgents[$0] } ?? "" }, set: { model.setSiteUserAgent(host, $0.isEmpty ? nil : $0) })) {
            Text("This browser (normal)").tag("")
            ForEach(UserAgentPreset.all) { Text($0.title).tag($0.id) }
        }
        Toggle("Switch WebRTC off for all sites", isOn: $model.blockWebRTC)
        if model.blockWebRTC {
            Toggle("Allow WebRTC on \(TabOrganizing.siteName(forHost: host)) (video calls)", isOn: Binding(
                get: { key.map { model.webRTCExceptions.contains($0) } ?? false },
                set: { model.setWebRTCException(host: host, allowed: $0) }))
        }
        Toggle("Allow JavaScript on this site", isOn: Binding(
            get: { model.scriptsAllowed(forHost: host) },
            set: { model.setScripts(host: host, allowed: $0) }))
        Toggle("Never put this site's tabs to sleep", isOn: Binding(
            get: { model.neverSleeps(host: host) },
            set: { model.setNeverSleeps(host: host, $0) }))
        if model.randomizeFingerprint {
            Toggle("Randomize canvas, audio and processor details here", isOn: Binding(
                get: { key.map { !model.fingerprintExceptions.contains($0) } ?? true },
                set: { model.setFingerprintException(host: host, allowed: !$0) }))
        }
        Text("WebRTC lets a page learn this device's address on your network. Switching it off applies to pages opened after the change. Camera and microphone requests are asked about separately.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var rulesSection: some View {
        Section {
            ForEach(model.siteDeleteRules) { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.hosts.joined(separator: ", ")).lineLimit(2)
                    Text("\(rule.trigger.title) · \(rule.scope.title)").font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Delete", role: .destructive) { model.setSiteDeleteRules(model.siteDeleteRules.filter { $0.id != rule.id }) } }
                .contextMenu { Button("Delete Rule", role: .destructive) { model.setSiteDeleteRules(model.siteDeleteRules.filter { $0.id != rule.id }) } }
            }
            TextField("Sites, separated by commas (a category)", text: $ruleHosts).autocorrectionDisabled()
            Picker("When", selection: $ruleTrigger) { ForEach(SiteDeleteRule.Trigger.allCases) { Text($0.title).tag($0) } }
            Picker("Clear", selection: $ruleScope) { ForEach(SiteDeleteRule.Scope.allCases) { Text($0.title).tag($0) } }
            Button("Add Rule") {
                model.addSiteDeleteRule(hosts: ruleHosts.split(separator: ",").map(String.init), trigger: ruleTrigger, scope: ruleScope)
                ruleHosts = ""
            }
            .disabled(ruleHosts.trimmingCharacters(in: .whitespaces).isEmpty)
            if let host, ruleHosts.isEmpty { Button("Use \(TabOrganizing.siteName(forHost: host))") { ruleHosts = TabOrganizing.siteName(forHost: host) } }
        } header: { Text("Clear Sites Automatically") } footer: {
            Text("A rule can name one site or a list of sites that belong together, such as the shops you do not want remembered.")
        }
    }

    private func refresh() async {
        report = nil; security = nil
        if let host { report = await model.siteReport(host: host) }
    }

    private func runSecurityCheck() async {
        checking = true
        security = await model.active?.engine.securityReport()
        checking = false
    }
}
