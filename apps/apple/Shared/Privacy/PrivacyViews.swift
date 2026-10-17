import SetuPrivacyCore
import SwiftUI

// MARK: - Address-bar shield

/// Shows "Protected by VayuSetu" only while rules are confirmed installed. Otherwise it shows an accurate status word.
/// State is conveyed by icon shape and text as well as colour.
struct ShieldButton: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var privacy: PrivacyController
    let host: String?
    var showLabel = true
    @State private var showPopover = false

    private var state: ProtectionState { privacy.state(forHost: host) }

    private var shortLabel: String {
        switch state {
        case .active: "Protected by VayuSetu"
        case .partial: "Needs attention"
        case .disabled: "Protection off"
        case .exception: "Off for this site"
        case .updating: "Updating"
        case .error: "Unavailable"
        }
    }

    private var tint: Color {
        switch state {
        case .active: .green
        case .partial, .error: .orange
        case .disabled, .exception: .secondary
        case .updating: Theme.accent
        }
    }

    var body: some View {
        Button { showPopover.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                if showLabel {
                    HStack(spacing: 4) {
                        Image(systemName: state.symbol).foregroundStyle(tint)
                        Text(shortLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
                Image(systemName: state.symbol).foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
        .help(state.headline)
        .accessibilityLabel(state.headline)
        .accessibilityValue(state.detail ?? state.statusWord)
        .accessibilityHint("Opens privacy controls")
        .accessibilityIdentifier("shield-button")
        #if DEBUG
        .onChange(of: model.privacyPopoverRequested) { _, requested in if requested { showPopover = true } }
        #endif
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            PrivacyPopover(privacy: privacy, host: host) { showPopover = false }
        }
    }
}

// MARK: - Popover

/// The protection card: how things stand, the three levels, this site's switch and the state of the lists. Deep black, like the rest of
/// the floating interface, with white text; the level highlight slides between choices.
struct PrivacyPopover: View {
    @ObservedObject var privacy: PrivacyController
    let host: String?
    var dismiss: () -> Void = {}
    @Namespace private var highlight

    private var state: ProtectionState { privacy.state(forHost: host) }
    private var level: ProtectionMode { privacy.configuration.mode }
    private var cleanHost: String? { host.flatMap { $0.isEmpty ? nil : ($0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0) } }
    private var siteOn: Bool { !privacy.configuration.isException(host: host) }

    private var tint: Color {
        switch state {
        case .active: Color(red: 0.30, green: 0.80, blue: 0.48)
        case .partial, .error: .orange
        case .updating: Color(red: 0.40, green: 0.65, blue: 1.0)
        case .disabled, .exception: Color.white.opacity(0.45)
        }
    }

    private var title: String {
        switch state {
        case .active: "Protected"
        case .partial: "Mostly protected"
        case .disabled: "Protection is off"
        case .exception: "Off for this site"
        case .updating: "Updating"
        case .error: "Unavailable"
        }
    }

    private var subtitle: String {
        switch state {
        case .active, .partial, .updating: cleanHost.map { "\($0) · \(level.title) level" } ?? "\(level.title) level"
        case .exception: cleanHost ?? "This website"
        case .disabled: "Turn protection on in Settings"
        case .error: state.detail ?? ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            levelPicker
            if cleanHost != nil, privacy.configuration.isEnabled { siteSwitch }
            listsStatus
            Text("Powered by VayuSetu")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.32)).frame(maxWidth: .infinity)
        }
        .padding(18)
        .frame(width: 330)
        .environment(\.colorScheme, .dark)
        .background(Obsidian.fill)
        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: level)
        .motion(.easeOut(duration: 0.2), value: state)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy-popover")
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 52, height: 52)
                Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.8).frame(width: 52, height: 52)
                Image(systemName: state.symbol).font(.system(size: 23, weight: .semibold)).foregroundStyle(tint)
            }
            .shadow(color: tint.opacity(state.isProtected ? 0.45 : 0.15), radius: 12)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(ProtectionMode.levels) { mode in
                    Button { privacy.setMode(mode) } label: {
                        VStack(spacing: 5) {
                            Text(mode.title).font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 3) {
                                ForEach(0..<3, id: \.self) { bar in
                                    Capsule().fill(bar < strength(mode) ? Color.white.opacity(mode == level ? 0.95 : 0.55) : Color.white.opacity(0.16))
                                        .frame(width: 11, height: 3.5)
                                }
                            }
                        }
                        .foregroundStyle(mode == level ? Color.white : Color.white.opacity(0.62))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background {
                            if mode == level {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent)
                                    .matchedGeometryEffect(id: "level", in: highlight)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(mode == level ? [.isSelected] : [])
                    .accessibilityIdentifier("protection-level-\(mode.rawValue)")
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.07)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protection-level")
            Text(level.summary)
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .id(level)
                .transition(.opacity)
        }
    }

    private func strength(_ mode: ProtectionMode) -> Int {
        switch mode { case .light: 1; case .balanced: 2; default: 3 }
    }

    private var siteSwitch: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).frame(width: 20)
            Text("Protect this site").font(.system(size: 13.5)).foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: Binding(get: { siteOn }, set: { _ in privacy.toggleSite(host: host) }))
                .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var listsStatus: some View {
        HStack(spacing: 10) {
            Group {
                if privacy.isUpdatingLists { ProgressView().controlSize(.small) }
                else { Image(systemName: privacy.standardListsReady ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(privacy.standardListsReady ? Color.white.opacity(0.5) : Theme.accent) }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(privacy.isUpdatingLists ? "Downloading protection lists…" : (privacy.standardListsReady ? "Lists are ready" : "Built-in rules are protecting you"))
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Text(listsDetail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            if !privacy.standardListsReady && !privacy.isUpdatingLists && privacy.configuration.isEnabled {
                Button("Download") { Task { await privacy.updateLists() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 2)
    }

    private var listsDetail: String {
        if let total = privacy.snapshot?.totalRules, total > 0 {
            return "\(total.formatted()) rules active" + (privacy.configuration.lastSuccessfulUpdate.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? "")
        }
        return privacy.isUpdatingLists ? "This only takes a moment" : "Choose a level above"
    }
}

// MARK: - Settings

/// "Privacy protection powered by VayuSetu" — the single place these controls live in Settings.
struct VayuProtectionSection: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var privacy: PrivacyController
    @State private var sheet: PrivacySheet?

    private var last: String {
        guard let date = privacy.configuration.lastSuccessfulUpdate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Group {
            Section {
                Picker("Protection Mode", selection: Binding(get: { privacy.configuration.mode }, set: { privacy.setMode($0) })) {
                    ForEach(ProtectionMode.levels) { Text($0.title).tag($0) }
                }
                Text(privacy.configuration.mode.summary).font(.caption).foregroundStyle(.secondary)
                if privacy.configuration.mode == .strict {
                    Label("Strict mode blocks third-party requests to tracking-style endpoints and third-party cookies. Some websites may not sign in or load correctly.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Ad Blocking", isOn: Binding(get: { privacy.configuration.adBlocking }, set: { on in
                    Task { let allowed = on ? true : await model.requireAuthentication("Turn off ad blocking"); if allowed { privacy.setAdBlocking(on) } }
                }))
                Toggle("Anti-Tracking", isOn: Binding(get: { privacy.configuration.antiTracking }, set: { on in
                    Task { let allowed = on ? true : await model.requireAuthentication("Turn off anti-tracking"); if allowed { privacy.setAntiTracking(on) } }
                }))
                LabeledContent("Status", value: privacy.state(forHost: nil).statusWord)
                Button("Custom Rules…") { sheet = .rules }
                Button("Website Exceptions…") { sheet = .exceptions }
                Button(privacy.isUpdatingLists ? "Updating…" : "Update Now") { Task { await privacy.updateLists() } }
                    .disabled(privacy.isUpdatingLists)
                Toggle("Update lists automatically (at most weekly, at launch)", isOn: Binding(
                    get: { privacy.configuration.automaticUpdates }, set: { privacy.setAutomaticUpdates($0) }))
                LabeledContent("Last Successful Update", value: last)
                if let status = privacy.listUpdateStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                Button("Diagnostics…") { sheet = .diagnostics }
                Button("Privacy Information…") { sheet = .info }
            } header: {
                Text("VayuSetu Protection")
            } footer: {
                Text("Privacy protection powered by VayuSetu. Built-in ad blocking and anti-tracking.")
            }
        }
        .sheet(item: $sheet) { PrivacySheetView(kind: $0, privacy: privacy) }
    }

    private func custom(_ keyPath: WritableKeyPath<PrivacyConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { privacy.configuration[keyPath: keyPath] }, set: { value in try? privacy.change { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Management sheets

struct PrivacySheetView: View {
    let kind: PrivacySheet
    @ObservedObject var privacy: PrivacyController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch kind {
                case .lists: FilterListsView(privacy: privacy)
                case .rules: CustomRulesView(privacy: privacy)
                case .exceptions: SiteExceptionsView(privacy: privacy)
                case .diagnostics: PrivacyDiagnosticsView(privacy: privacy)
                case .info: PrivacyInfoView()
                }
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    private var title: String {
        switch kind {
        case .lists: "Filter Lists"
        case .rules: "Custom Rules"
        case .exceptions: "Website Exceptions"
        case .diagnostics: "Protection Diagnostics"
        case .info: "Privacy Information"
        }
    }
}

struct FilterListsView: View {
    @ObservedObject var privacy: PrivacyController

    private func stateText(_ url: String) -> String {
        guard let state = privacy.configuration.listStates[url] else { return "Not downloaded" }
        return "\(state.ruleCount) rules · \(state.unsupported) unsupported · updated \(state.updatedAt.formatted(date: .abbreviated, time: .omitted)) · \(state.contentHash.prefix(8))"
    }

    var body: some View {
        List {
            Section("Built in") {
                ForEach(BundledLists.all, id: \.id) { list in
                    VStack(alignment: .leading) {
                        Text(list.name)
                        Text("Always available offline. First-party list; no third-party text is redistributed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(FilterCatalog.grouped(), id: \.0) { category, lists in
                    DisclosureGroup(category.rawValue) {
                        ForEach(lists) { list in
                            Toggle(isOn: Binding(get: { privacy.configuration.enabledListURLs.contains(list.url) },
                                                 set: { privacy.setList(list.url, enabled: $0) })) {
                                VStack(alignment: .leading) {
                                    Text(list.name)
                                    Text(list.summary).font(.caption).foregroundStyle(.secondary)
                                    Text(stateText(list.url)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Downloadable lists")
            } footer: {
                Text("Downloaded lists apply in Custom mode only. Nothing is downloaded until you choose Update Now (or turn on automatic updates). Each list belongs to its publisher and is fetched directly from them; BrowserSetu does not redistribute it. Check each list's own licence before relying on it.")
            }
        }
    }
}

struct CustomRulesView: View {
    @ObservedObject var privacy: PrivacyController
    @State private var domain = ""
    @State private var action: FilterAction = .block
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("example.com", text: $domain).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Picker("", selection: $action) { Text("Block").tag(FilterAction.block); Text("Allow").tag(FilterAction.allow) }
                        .labelsHidden().frame(width: 90)
                    Button("Add") { add() }.disabled(domain.isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Applies to the domain and its subdomains. Your rules outrank filter lists and website exceptions; when two of your rules overlap, the more specific one wins.")
            }
            Section("Your Rules") {
                if privacy.configuration.userRules.isEmpty { Text("No custom rules").foregroundStyle(.secondary) }
                ForEach(privacy.configuration.userRules) { rule in
                    HStack {
                        Image(systemName: rule.action == .block ? "nosign" : "checkmark.circle")
                        Text(rule.domain)
                        Spacer()
                        Text(rule.action == .block ? "Block" : "Allow").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { remove(rule) }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func add() {
        do {
            try privacy.change { try $0.addUserRule(domain: domain, action: action) }
            domain = ""; error = nil
        } catch PrivacyConfiguration.ConfigurationError.duplicate {
            error = "That rule already exists."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Enter a valid website name such as example.com."
        }
    }

    private func remove(_ rule: UserRule) {
        try? privacy.change { $0.userRules.removeAll { $0.id == rule.id } }
    }
}

struct SiteExceptionsView: View {
    @ObservedObject var privacy: PrivacyController
    @State private var domain = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("example.com", text: $domain).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Add") { add() }.disabled(domain.isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Protection is off on these websites and their subdomains. Your own Block rules still apply.")
            }
            Section("Protection off for") {
                if privacy.configuration.siteExceptions.isEmpty { Text("No exceptions").foregroundStyle(.secondary) }
                ForEach(privacy.configuration.siteExceptions, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Remove", role: .destructive) { try? privacy.change { $0.removeSiteException(site) } }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func add() {
        do {
            try privacy.change { try $0.addSiteException(domain) }
            domain = ""; error = nil
        } catch PrivacyConfiguration.ConfigurationError.duplicate {
            error = "That website is already listed."
        } catch {
            self.error = "Enter a valid website name such as example.com."
        }
    }
}

struct PrivacyDiagnosticsView: View {
    @ObservedObject var privacy: PrivacyController

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Protection", value: privacy.state(forHost: nil).headline)
                if let detail = privacy.state(forHost: nil).detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Installed rule set", value: privacy.report?.identifier.map { String($0.suffix(10)) } ?? "None")
                LabeledContent("Open tabs protected", value: "\(privacy.report?.attachedWebViews ?? 0)")
                LabeledContent("Last install", value: privacy.report.map { $0.reusedCompiledList ? "Reused compiled rules" : String(format: "Compiled in %.0f ms", $0.compileMilliseconds) } ?? "—")
                LabeledContent("Build time (parse + compile)", value: String(format: "%.0f ms", privacy.lastBuildMilliseconds))
            }
            if let snapshot = privacy.snapshot {
                Section("Installed rules") {
                    LabeledContent("Domain block rules", value: "\(snapshot.domainBlockRules)")
                    LabeledContent("URL-pattern rules", value: "\(snapshot.urlBlockRules)")
                    LabeledContent("Element-hiding rules", value: "\(snapshot.elementHidingRules)")
                    LabeledContent("Your rules", value: "\(snapshot.userRules)")
                    LabeledContent("Website exceptions", value: "\(snapshot.siteExceptions)")
                    ForEach(snapshot.strictExtras, id: \.self) { Label($0, systemImage: "checkmark") }
                    LabeledContent("Unsupported syntax skipped", value: "\(snapshot.unsupportedRules)")
                    LabeledContent("Dropped for compile budget", value: "\(snapshot.droppedForBudget)")
                    ForEach(snapshot.failedLists.sorted(by: { $0.key < $1.key }), id: \.key) { name, reason in
                        Label("\(name): \(reason)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            Section("What this can and cannot do") {
                ForEach(PrivacyCapabilities.all) { capability in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(capability.name, systemImage: capability.supported ? "checkmark.circle" : "minus.circle")
                        Text(capability.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacyInfoView: View {
    var body: some View {
        Form {
            Section("Privacy protection powered by VayuSetu") {
                Text("Built-in ad blocking and anti-tracking runs inside BrowserSetu. It uses WebKit's content blocker, so blocking happens before a request is sent.")
                Text("BrowserSetu does not require the VayuSetu app, does not talk to it, and works fully offline.")
            }
            Section("What stays on your device") {
                Text("Your settings, rules and exceptions are stored in your profile on this device.")
                Text("BrowserSetu collects no analytics and sends no usage or browsing data anywhere.")
            }
            Section("What it connects to") {
                Text("Websites you open. Public filter lists for your protection level, downloaded the first time and again when you choose Update Now or turn on automatic updates; those requests contain no page addresses, history or identifiers. And, only if you leave them on, your search engine (as you type, for suggestions) and each site\u{2019}s small icon (from the site itself). All three can be turned off in Settings.")
            }
            Section("Limits") {
                Text("No blocker catches every tracker. Websites can still identify you in other ways, and private browsing is not anonymity.")
            }
        }
        .formStyle(.grouped)
    }
}
