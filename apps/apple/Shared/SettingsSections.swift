import SetuPrivacyCore
import SwiftUI
import UniformTypeIdentifiers

// Reusable Settings sections. The Mac Settings window and the iOS settings screen both compose these, so every
// control has one implementation and reads and writes the one `BrowserModel`.

// MARK: - General

struct StartupSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Startup") {
            Picker("When Browser Setu opens", selection: $model.startup) {
                Text("Restore last session").tag("restore")
                Text("Start with a new tab").tag("blank")
                Text("Open my homepage").tag("homepage")
            }
            if model.startup == "homepage" {
                TextField("https://example.com", text: $model.homepage).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                if !model.homepage.isEmpty && model.homepageURL == nil {
                    Label("Use a full web address starting with https:// or http://. Until then a new tab opens.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text(model.startup == "restore" ? "Restored tabs load only when you select them." : " ").font(.caption).foregroundStyle(.secondary)
            NewTabSettings()
        }
    }
}

// MARK: - Search

struct SearchSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var custom = ""
    @State private var showingCustom = false
    @State private var invalid = false

    private static let customTag = "custom"

    private var selection: String {
        if showingCustom { return Self.customTag }
        return SearchEngines.preset(for: model.searchTemplate)?.id ?? Self.customTag
    }

    var body: some View {
        Group {
            Section("Search Engine") {
                Picker("Search with", selection: Binding(get: { selection }, set: choose)) {
                    ForEach(SearchEngines.presets) { Text($0.name).tag($0.id) }
                    Text("Custom…").tag(Self.customTag)
                }
                if selection == Self.customTag {
                    TextField("Search address (https, with {} where the words go)", text: $custom)
                        .autocorrectionDisabled()
                        .onSubmit(applyCustom)
                    HStack {
                        Button("Use This Address", action: applyCustom).disabled(custom.isEmpty)
                        if invalid { Text("That address needs https and exactly one {}.").font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            Section {
                Toggle("Show suggestions from the search engine", isOn: $model.searchSuggestionsEnabled)
                    .disabled(SearchSuggestions.endpoint(forSearchTemplate: model.searchTemplate) == nil)
                Text(SearchSuggestions.endpoint(forSearchTemplate: model.searchTemplate) == nil
                     ? "This search engine does not offer suggestions to browsers. Your own tabs, bookmarks and history are still suggested."
                     : "While you type, what you have typed is sent to \(SearchEngines.preset(for: model.searchTemplate)?.name ?? "the search engine") so it can suggest searches. Nothing is sent from private tabs, or for anything that looks like a web address. Your own tabs, bookmarks and history are always suggested on this device. Turn this off to send nothing until you press Return.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .motion(.easeOut(duration: 0.22), value: selection)
        .motion(.easeOut(duration: 0.2), value: invalid)
        .onAppear { custom = SearchEngines.preset(for: model.searchTemplate) == nil ? model.searchTemplate : "" }
    }

    private func choose(_ id: String) {
        invalid = false
        if let preset = SearchEngines.presets.first(where: { $0.id == id }) {
            showingCustom = false
            model.setSearchTemplate(preset.template)
        } else {
            showingCustom = true
        }
    }

    private func applyCustom() {
        guard model.setSearchTemplate(custom) else { invalid = true; return }
        invalid = false
        showingCustom = SearchEngines.preset(for: model.searchTemplate) == nil
        custom = model.searchTemplate
    }
}

// MARK: - Privacy and security

/// The three VayuSetu levels, and nothing else: no filter lists and no per-feature switches.
struct VayuLevelSection: View {
    @ObservedObject var privacy: PrivacyController
    @State private var showInfo = false

    private static let levels: [ProtectionMode] = [.light, .balanced, .strict]

    private var allOn: Bool { privacy.configuration.adBlocking && privacy.configuration.antiTracking }

    var body: some View {
        Section {
            Picker("Protection Level", selection: Binding<ProtectionMode?>(
                get: { Self.levels.contains(privacy.configuration.mode) ? privacy.configuration.mode : nil },
                set: { if let mode = $0 { privacy.setMode(mode) } })) {
                ForEach(Self.levels) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            Text(privacy.configuration.mode == .custom
                 ? "A custom setup from an earlier version is in use. Choosing a level replaces it."
                 : privacy.configuration.mode.summary)
                .font(.caption).foregroundStyle(.secondary)
            if !allOn {
                Label("Some protection is switched off.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Button("Turn On All Protection") { privacy.setAdBlocking(true); privacy.setAntiTracking(true) }
            }
            LabeledContent("Status", value: privacy.state(forHost: nil).statusWord)
            DisclosureGroup("Filter data") {
                LabeledContent("Lists for this level", value: privacy.isUpdatingLists ? "Downloading…" : (privacy.standardListsReady ? "Ready" : "Not downloaded yet"))
                LabeledContent("Last updated", value: privacy.configuration.lastSuccessfulUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                Button(privacy.isUpdatingLists ? "Updating…" : "Update Now") { Task { await privacy.updateLists() } }
                    .disabled(privacy.isUpdatingLists)
                if let status = privacy.listUpdateStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Button("Privacy Information…") { showInfo = true }
        } header: {
            Text("VayuSetu Protection")
        } footer: {
            Text("Privacy protection powered by VayuSetu. Built-in ad blocking and anti-tracking.")
        }
        .motion(.easeOut(duration: 0.22), value: privacy.configuration.mode)
        .motion(.easeOut(duration: 0.2), value: allOn)
        .sheet(isPresented: $showInfo) { PrivacySheetView(kind: .info, privacy: privacy) }
    }
}

/// Facts about how the browser protects the user, stated only where the behaviour exists.
struct SecurityFactsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Security") {
            Picker("Referrer sent to other sites", selection: $model.referrerMode) {
                ForEach(ReferrerMode.allCases) { Text($0.title).tag($0) }
            }
            Text(model.referrerMode.summary).font(.caption).foregroundStyle(.secondary)
            Label("Websites are upgraded to HTTPS when WebKit knows they support it.", systemImage: "lock")
            Label("WebKit’s deceptive-website warning is on.", systemImage: "exclamationmark.shield")
            Label("A link that would open another app asks you first.", systemImage: "arrow.up.forward.app")
            Label("Downloaded files are never opened automatically, and a name that is already taken is never overwritten.", systemImage: "arrow.down.circle")
        }
        .labelStyle(.titleAndIcon)
    }
}

struct ThreatListSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var importing = false

    var body: some View {
        Section("Threat List") {
            if model.threatList.isEmpty {
                Text("No list imported.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Hosts on your list", value: "\(model.threatList.count)")
            }
            Button("Import a List of Hosts…") { importing = true }
            if !model.threatList.isEmpty { Button("Remove the List", role: .destructive) { model.clearThreatList() } }
            Text("Pages on this list show a warning before they load. The list is a text file you choose, one host per line (hosts-file and ad-block formats work too). It stays on this device, and no address you visit is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in
            if case .success(let url) = result { model.importThreatList(from: url) }
        }
    }
}

struct ProxySection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var kind = ProxyConfig.Kind.http
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var password = ""
    @State private var problem: String?

    var body: some View {
        Section("Proxy") {
            Toggle("Use a proxy", isOn: Binding(get: { model.proxyEnabled }, set: { model.setProxyEnabled($0) }))
                .disabled(model.proxy == nil)
                .accessibilityIdentifier("proxy-toggle")
            Picker("Type", selection: $kind) { ForEach(ProxyConfig.Kind.allCases) { Text($0.title).tag($0) } }
            TextField("Address", text: $host).autocorrectionDisabled().accessibilityIdentifier("proxy-host")
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
            TextField("Port", text: $port).autocorrectionDisabled().accessibilityIdentifier("proxy-port")
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TextField("User name (optional)", text: $user).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("Password (optional)", text: $password)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Button(model.proxy == nil ? "Save and Use" : "Save Changes") {
                switch ProxyConfig.validated(kind: kind, host: host, port: port, username: user) {
                case .success(let config): problem = nil; model.saveProxy(config, password: password); password = ""
                case .failure(let error): problem = error.localizedDescription
                }
            }
            if model.proxy != nil { Button("Forget This Proxy", role: .destructive) { model.forgetProxy(); host = ""; port = ""; user = ""; password = "" } }
            Text(model.proxyEnabled ? "Page loads go through \(model.proxy?.summary ?? "your proxy"). If the proxy cannot be reached, pages do not load; nothing falls back to a direct connection. Site icons are paused so they cannot reveal your address, but blocking-list updates are not sent through the proxy."
                 : "Enter a proxy you already have. This is not a VPN: only the browser’s page loads use it, and your network can still see the proxy’s address. The password is kept in the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard let saved = model.proxy else { return }
            kind = saved.kind; host = saved.host; port = String(saved.port); user = saved.username
        }
    }
}

struct SiteZoomSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Page Zoom") {
            if model.siteZoom.isEmpty {
                Label("No site has its own zoom", systemImage: "plus.magnifyingglass").foregroundStyle(.secondary)
            } else {
                ShowMoreRows(model.siteZoom.sorted(by: { $0.key < $1.key }), id: \.key) { host, factor in
                    HStack {
                        Text(host)
                        Spacer()
                        Text("\(Int((factor * 100).rounded()))%").foregroundStyle(.secondary)
                        Button { model.rememberZoom(1, forHost: host) } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless)
                    }
                }
                Button("Reset All Sites to 100%", role: .destructive) { model.forgetAllSiteZoom() }
            }
        }
    }
}

struct ClearOnQuitSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("When the Browser Closes") {
            Picker("Clear", selection: $model.clearOnQuit) {
                ForEach(ClearOnQuit.allCases) { Text($0.title).tag($0) }
            }
            Text("What you choose is deleted as Browser Setu opens next, before any page loads. Clearing cookies and website data signs you out of sites. Bookmarks and passwords are never touched.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Short words that pick a search engine for one search: type "yt trailers" or "w Ada Lovelace" in the address bar.
struct SearchShortcutsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var keyword = ""
    @State private var address = ""
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(SearchShortcuts.builtIn, id: \.keyword) { entry in
                LabeledContent(entry.keyword, value: entry.name)
            }
            ShowMoreRows(model.customSearchShortcuts.sorted(by: { $0.key < $1.key }), id: \.key) { key, template in
                HStack {
                    VStack(alignment: .leading) { Text(key).fontWeight(.medium); Text(template).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Button(role: .destructive) { var map = model.customSearchShortcuts; map[key] = nil; model.setSearchShortcuts(map) } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Word", text: $keyword).frame(maxWidth: 80).autocorrectionDisabled()
                TextField("https://example.com/search?q={}", text: $address).autocorrectionDisabled()
                Button("Add") { add() }.disabled(keyword.isEmpty || address.isEmpty)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Search Shortcuts")
        } footer: {
            Text("Type the word, a space, then what to search for. Your own words win over the built-in ones. The address needs https and {} where the search goes.")
        }
    }

    private func add() {
        let word = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard word.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil else { problem = "A word is 1 to 10 letters or numbers."; return }
        guard let valid = SearchEngines.validated(address) else { problem = "The address needs https and exactly one {}."; return }
        var map = model.customSearchShortcuts
        map[word] = valid
        model.setSearchShortcuts(map)
        keyword = ""; address = ""; problem = nil
    }
}

/// Asks for Touch ID, Face ID or the device passcode before the changes that matter most.
struct SensitiveLockSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Toggle("Require Touch ID, Face ID or passcode", isOn: Binding(get: { model.lockSensitiveSettings }, set: { on in Task { await model.setLockSensitiveSettings(on) } }))
        } header: {
            Text("Sensitive Changes")
        } footer: {
            Text("Asked before backing up or restoring, clearing browsing data, adding or removing extensions and scripts, turning protection off, and deleting a profile. Turning this on or off asks too. If this device has no passcode, nothing is asked.")
        }
    }
}

/// Sign-ins the user chose to keep for websites' own sign-in boxes, in the Keychain, for this profile only.
struct SavedSignInsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var entries: [SignInVault.Entry] = []
    @State private var logins: [WebLogin] = []
    @State private var saving = true
    @State private var editing: WebLogin?
    @State private var adding = false
    @State private var findings: [String: BreachCheck.Finding] = [:]
    @State private var checking = false
    @State private var checkSummary: String?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Section {
            Toggle("Offer to save passwords", isOn: Binding(get: { saving }, set: { saving = $0; model.setSaveLogins($0) }))
            Toggle("Keep my passwords in iCloud Keychain", isOn: Binding(get: { model.passwordsInICloudKeychain }, set: { on in Task { await model.setPasswordsInICloudKeychain(on) } }))
            Text("Your saved passwords appear on your other Apple devices that use the same Apple Account, sealed end to end by Apple. Off keeps them on this device only. Needs iCloud Keychain on, and Browser Setu on those devices.")
                .font(.caption).foregroundStyle(.secondary)
            ShowMoreRows(logins) { login in
                HStack {
                    VStack(alignment: .leading) {
                        Text(URL(string: login.origin)?.host ?? login.origin).fontWeight(.medium)
                        Text(login.user).font(.caption).foregroundStyle(.secondary)
                        if PasswordStrength.evaluate(login.password, user: login.user).isWeak {
                            Label("Weak password", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                        if let finding = findings[login.id], finding.isProblem {
                            Label(problemText(finding), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Copy") { Task { if await model.requireAuthentication("Copy a saved password") { copyToPasteboard(login.password); model.notice = "Password copied." } } }.buttonStyle(.borderless)
                    Button("Edit") { editing = login }.buttonStyle(.borderless)
                    Button(role: .destructive) {
                        Task { if await model.requireAuthentication("Remove a saved password") { WebLoginVault.forget(login, profile: model.profileName); load() } }
                    } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                }
            }
            Button("Add a Password…") { adding = true }
            if !logins.isEmpty {
                HStack {
                    Button(checking ? "Checking…" : "Check Passwords for Leaks…") { startCheck() }.disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                }
                if let checkSummary { Text(checkSummary).font(.caption).foregroundStyle(.secondary).transition(.opacity) }
            }
            if !model.neverSaveOrigins.isEmpty {
                ShowMoreRows(model.neverSaveOrigins.sorted(), id: \.self) { origin in
                    HStack { Text("Never offered for \(URL(string: origin)?.host ?? origin)").font(.caption); Spacer(); Button("Allow Again") { model.allowSavingLogins(for: origin); load() } }
                }
            }
            if entries.isEmpty { Label("No saved sign-ins", systemImage: "key").foregroundStyle(.secondary) }
            ShowMoreRows(entries, id: \.account) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.host).fontWeight(.medium)
                        Text(entry.user + (entry.realm.isEmpty ? "" : " · " + entry.realm) + (entry.isCurrentFormat ? "" : " · saved by an older version, you will be asked again")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { if await model.requireAuthentication("Remove a saved sign-in") { SignInVault.forget(account: entry.account, profile: model.profileName); load() } }
                    } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Saved Sign-ins")
        } footer: {
            Text("For the plain name-and-password boxes some websites show. Kept in your Keychain, on this device, for this profile only, and never in private tabs. Passwords for web pages are offered for saving after you sign in, kept in the same Keychain, and filled only after Touch ID or your password. Nothing is saved in private tabs. Nothing is sent to any server, except when you choose Check Passwords for Leaks: then only the first five characters of a one-way code for each password go to haveibeenpwned.com, never a password, a site or a user name.")
        }
        .onAppear(perform: load)
        .onDisappear { checkTask?.cancel(); findings = [:]; checkSummary = nil; checking = false }
        .sheet(item: $editing, onDismiss: load) { LoginEditor(original: $0) }
        .sheet(isPresented: $adding, onDismiss: load) { LoginEditor(original: nil) }
    }

    private func load() { entries = SignInVault.list(profile: model.profileName); logins = WebLoginVault.list(profile: model.profileName); saving = model.saveLoginsEnabled }

    private func problemText(_ finding: BreachCheck.Finding) -> String {
        var parts: [String] = []
        if finding.leaks > 0 { parts.append("Found in \(finding.leaks.formatted()) known leaks. Change it.") }
        if !finding.reusedOn.isEmpty { parts.append("Also used on " + finding.reusedOn.prefix(2).joined(separator: ", ") + (finding.reusedOn.count > 2 ? " and \(finding.reusedOn.count - 2) more" : "") + ".") }
        return parts.joined(separator: " ")
    }

    /// Asks for Touch ID first, because the passwords are read to be hashed, then looks them up. The result is shown here and kept nowhere.
    private func startCheck() {
        checkTask?.cancel()
        checkTask = Task {
            guard await model.requireAuthentication("Check saved passwords for leaks") else { return }
            animated(.easeOut(duration: 0.2)) { checking = true; checkSummary = nil }
            let current = WebLoginVault.list(profile: model.profileName)
            do {
                let result = try await BreachCheck.scan(current)
                animated(.easeOut(duration: 0.2)) { findings = result; checkSummary = BreachCheck.summary(result, checked: current.count); checking = false }
            } catch {
                animated(.easeOut(duration: 0.2)) { checkSummary = "Could not reach the service. Check your connection and try again."; checking = false }
            }
        }
    }
}

/// The honest state of passwords and passkeys.
struct PasswordsInfoSection: View {
    var body: some View {
        Section {
            Label("Browser Setu keeps its own passwords in your Keychain on this device. It cannot use Safari’s Passwords or iCloud Keychain: Apple does not give other browsers that.", systemImage: "key.fill")
            Label("Passkeys for websites need an Apple permission for browsers that has to be requested from Apple. Until it is granted, a site that offers a passkey will let you sign in another way.", systemImage: "person.badge.key")
        } header: {
            Text("Passwords and Passkeys")
        }
        .font(.callout)
    }
}

struct DarkPagesSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Dark Pages") {
            Picker("Show light pages dark", selection: $model.darkPages) {
                ForEach(DarkPages.allCases) { Text($0.title).tag($0) }
            }
            Text("Inverts light pages, keeping pictures and video as they are. Pages that are already dark are left alone. With “Only sites I choose”, use Dark Page in the page menu on each site.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SiteIconsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Site Icons") {
            Toggle("Show each site’s icon", isOn: $model.fetchSiteIcons)
            Text("After a page loads in a normal tab, the browser downloads that site’s small icon from the site itself and keeps it on this device, to show beside its name in suggestions and lists. No cookies or account details are sent, and nothing is fetched in private tabs. Turning this off deletes the saved icons. Clearing browsing data deletes them too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LinkCleaningSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Link Cleaning") {
            Toggle("Remove tracking parameters from links", isOn: $model.stripTrackingParameters)
            Text("Strips campaign and click identifiers such as utm_source and fbclid before a page loads. Other parts of the link are left alone. Nothing is downloaded or sent.")
                .font(.caption).foregroundStyle(.secondary)
            if model.strippedLinkCount > 0 { LabeledContent("Cleaned this session", value: "\(model.strippedLinkCount)") }
        }
    }
}

struct BrowsingDataSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var confirmClear = false

    var body: some View {
        Section("Browsing Data") {
            Button("Clear history, downloads and website data…", role: .destructive) { Task { if await model.requireAuthentication("Clear your browsing data") { confirmClear = true } } }
        }
        .confirmationDialog("Clear browsing data for this profile?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { Task { await model.clearBrowsingData() } }
        }
    }
}

// MARK: - Websites

/// Each website's saved camera and microphone choice. Only what the browser asks about and enforces is listed.
struct SitePermissionsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var grants: [PermissionGrant] = []

    private static let kinds: [PermissionType] = [.camera, .microphone]

    private var origins: [String] {
        Array(Set(grants.filter { Self.kinds.contains($0.kind) }.map(\.origin))).sorted()
    }

    private func decision(_ origin: String, _ kind: PermissionType) -> Decision {
        grants.first { $0.origin == origin && $0.kind == kind }?.decision ?? .prompt
    }

    var body: some View {
        Section {
            if origins.isEmpty {
                Label("No saved decisions yet", systemImage: "camera").foregroundStyle(.secondary)
            }
            ShowMoreRows(origins, id: \.self) { origin in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(origin).fontWeight(.medium)
                        Spacer()
                        Button("Forget") { forget(origin) }
                    }
                    picker("Camera", origin, .camera)
                    picker("Microphone", origin, .microphone)
                }
                .padding(.vertical, 2)
            }
            Picker("Saved access lapses", selection: $model.permissionExpiry) {
                ForEach(PermissionExpiry.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("permission-expiry")
        } header: {
            Text("Camera and Microphone")
        } footer: {
            Text("Ask means the website asks again each time. “Lapses” turns Always Allow for the camera, microphone and location back into Ask after that time. Pop-ups from a page you did not click are always blocked.")
        }
        .onAppear(perform: load)
    }

    private func picker(_ title: String, _ origin: String, _ kind: PermissionType) -> some View {
        Picker(title, selection: Binding(get: { decision(origin, kind) }, set: { set(origin, kind, $0) })) {
            Text("Ask").tag(Decision.prompt)
            Text("Allow").tag(Decision.allow)
            Text("Deny").tag(Decision.deny)
        }
        .pickerStyle(.segmented)
    }

    private func set(_ origin: String, _ kind: PermissionType, _ value: Decision) {
        try? model.core.rememberPermission(origin: origin, kind: kind, decision: value)
        if value == .allow { model.notePermissionGranted(origin: origin, kinds: [kind]) }
        load()
    }

    private func forget(_ origin: String) {
        for kind in Self.kinds { try? model.core.rememberPermission(origin: origin, kind: kind, decision: .prompt) }
        load()
    }

    private func load() { grants = (try? model.core.listPermissions()) ?? [] }
}

struct WebsiteDataSection: View {
    @State private var show = false
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Website Data") {
            Button("Manage Website Data…") { show = true }
            Text("See which websites have stored cookies and other data in this profile, and remove any of them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $show) { SiteDataSheet().environmentObject(model) }
    }
}

// MARK: - Performance

struct MemorySettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var showHelp = false

    var body: some View {
        Section("Memory") {
            Picker("When memory is needed", selection: $model.memoryMode) {
                ForEach(MemoryMode.allCases) { Text($0.title).tag($0) }
            }
            Text(model.memoryMode.summary).font(.caption).foregroundStyle(.secondary)
            if model.memoryMode == .custom {
                Picker("Keep this many recent tabs", selection: $model.customMemory.keepRecent) {
                    ForEach(CustomMemoryPolicy.keepChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Release a tab unused for", selection: $model.customMemory.idleMinutes) {
                    ForEach(CustomMemoryPolicy.idleChoices, id: \.self) { Text($0 >= 60 ? "\($0 / 60) h" : "\($0) min").tag($0) }
                }
            }
            Toggle("Switch to Battery Saver on a low battery or a hot device", isOn: $model.batteryAware)
            if let why = model.governor.effective.reason, model.governor.effective.mode != model.memoryMode {
                Label("Battery Saver is in force because \(why).", systemImage: "leaf").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Never release pinned tabs", isOn: $model.keepPinnedTabs)
            Toggle("Ask before closing a pinned tab", isOn: $model.protectPinned)
            HStack {
                LabeledContent("Released right now", value: "\(model.tabs.filter(\.isDiscarded).count)")
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless).help("How released tabs work")
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                        Text("A released tab keeps its title, address, history and scroll position and reloads when you open it. Tabs that are playing media, using the camera or microphone, or loading are never released, and neither are private tabs. A page with text you typed but did not submit can lose it, so pin such tabs.")
                            .font(.callout).frame(width: 300).padding(14)
                    }
            }
        }
    }
}

struct ResourceMonitorSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var memory: UInt64 = 0

    var body: some View {
        Section {
            Toggle("Show device network speed", isOn: $model.showSpeedPill)
            #if os(iOS)
            if model.showSpeedPill { Toggle("Pop up when the speed changes a lot", isOn: $model.speedPopups) }
            if model.showSpeedPill, !model.speedActivityStatus.isEmpty {
                Text(model.speedActivityStatus).font(.caption).foregroundStyle(.secondary)
            }
            #endif
            LabeledContent("Memory used by Browser Setu", value: ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))
                .help("This app's own process. Each web page runs in a separate WebKit process that Activity Monitor lists separately.")
            LabeledContent("Open tabs", value: "\(model.tabs.count)")
            LabeledContent("Pages loaded", value: "\(model.tabs.filter { $0.hasLoadedPage }.count) of \(model.tabs.count)")
            Button("Open Resource Dashboard") { model.sheet = .resources }.accessibilityIdentifier("open-resources")
        } header: {
            HStack {
                Text("Resource Snapshot")
                Spacer()
                Button { memory = currentMemoryFootprint() } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help("Refresh")
            }
        } footer: {
            Text("Network speed is the whole device's traffic, not only this browser's. It shows in the Dynamic Island on iPhone while the app is open, and in the corner of the window on Mac. It only reads the system's traffic counters and sends nothing.")
        }
        .onAppear { memory = currentMemoryFootprint() }
    }
}

// MARK: - Backup

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Making Browser Setu the browser that opens links from other apps.
struct DefaultBrowserSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var isDefault = false

    var body: some View {
        Section("Default Browser") {
            #if os(macOS)
            LabeledContent("Opens web links", value: isDefault ? "Browser Setu" : "Another browser")
            Button(isDefault ? "Browser Setu Is the Default" : "Make Browser Setu the Default") { makeDefault() }
                .disabled(isDefault)
            Text("Links you click in Mail, Messages and other apps would open here. macOS asks you to confirm.")
                .font(.caption).foregroundStyle(.secondary)
            #else
            Button("Open iPhone Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Text("Apple only lets an app be the default browser after it has been granted the default browser entitlement. Until then, links from other apps open in Safari, and “Share” can send a page here.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
        }
        #if os(macOS)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        #endif
    }

    #if os(macOS)
    private func refresh() {
        let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefault = current?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefault() {
        let app = Bundle.main.bundleURL
        Task {
            for scheme in ["https", "http"] { try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) }
            refresh()
        }
    }
    #endif
}

struct BookmarkHTMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.html] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// Moving bookmarks to and from other browsers, as an HTML file.
struct BookmarkTransferSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var importing = false
    @State private var exporting = false
    @State private var document = BookmarkHTMLDocument(text: "")

    var body: some View {
        Section("Bookmarks") {
            Button("Import Bookmarks…") { importing = true }
            Button("Export Bookmarks…") { document = BookmarkHTMLDocument(text: model.bookmarksHTML()); exporting = true }
            Toggle("Show bookmarks in Spotlight", isOn: $model.spotlightBookmarks)
            Text("Works with the HTML file that Safari, Chrome, Brave and Firefox export. Only web addresses are imported, and bookmarks you already have are not added twice. Spotlight lists only your bookmarks (their titles and sites), on this device; history and open pages are never added. Handoff passes the page in front, never a private tab, to your other devices signed in to the same Apple Account.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.html]) { result in
            guard case .success(let url) = result else { return }
            // Read and parsed away from the main thread, then added in small batches, so a file with thousands of bookmarks never freezes the window.
            let picked = url
            Task {
                let parsed: [BookmarkHTML.Entry]? = await Task.detached(priority: .userInitiated) {
                    let scoped = picked.startAccessingSecurityScopedResource()
                    defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: picked), data.count < 50_000_000 else { return nil }
                    return BookmarkHTML.parse(String(decoding: data, as: UTF8.self))
                }.value
                guard let parsed else { model.notice = "That file could not be read."; return }
                let r = await model.importBookmarks(entries: parsed)
                model.notice = r.added == 0 && r.skipped == 0 ? "No bookmarks were found in that file."
                    : "Imported \(r.added) bookmark\(r.added == 1 ? "" : "s")" + (r.skipped > 0 ? ", skipped \(r.skipped) already saved." : ".")
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .html,
                      defaultFilename: "Browser Setu Bookmarks") { result in
            if case .success = result { model.notice = "Bookmarks exported." }
        }
    }
}

/// Moving passwords and history to and from other browsers. Both files are plain text, so each step says so and asks first.
struct ImportExportSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var importingPasswords = false
    @State private var exportingPasswords = false
    @State private var importingHistory = false
    @State private var csvDocument = PasswordCSVDocument(text: "")
    @State private var confirmExport = false
    @State private var lastImportedFile: URL?
    @State private var askToDelete = false

    var body: some View {
        Section {
            Button("Import Passwords…") { importingPasswords = true }
            Button("Export Passwords…") { confirmExport = true }
            Button("Import History…") { importingHistory = true }
            Button("Copy a New Strong Password") { copyToPasteboard(PasswordGenerator.make()); model.notice = "A new password was copied. It stays on the clipboard until something else replaces it." }
        } header: { Text("Import and Export") } footer: {
            Text("Passwords: the CSV file from Chrome, Edge, Brave, Firefox or Apple's Passwords app. Sites that start with http (not https) are never imported. History: the JSON file from a Google Takeout \"Browser History\" export or Safari's Export Browsing History. A password file holds every password as plain text: delete it as soon as you have used it.")
        }
        .fileImporter(isPresented: $importingPasswords, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            lastImportedFile = url
            Task {
                let text: String? = await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
                    return String(decoding: data, as: UTF8.self)
                }.value
                guard let text else { model.notice = "That file could not be read."; return }
                let r = model.importPasswords(csv: text)
                model.notice = "Imported \(r.added) password\(r.added == 1 ? "" : "s")." + (r.skippedInsecure > 0 ? " \(r.skippedInsecure) for http sites were left out." : "") + (r.skippedDuplicate > 0 ? " \(r.skippedDuplicate) were already saved." : "")
                if r.added > 0 { askToDelete = true }
            }
        }
        .fileImporter(isPresented: $importingHistory, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let visits: [HistoryImport.Visit]? = await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url), data.count < 400_000_000 else { return nil }
                    return HistoryImport.parse(json: data)
                }.value
                guard let visits else { model.notice = "That file could not be read."; return }
                let count = await model.importHistory(visits)
                model.notice = count == 0 ? "No web pages were found in that file." : "Imported \(count) page\(count == 1 ? "" : "s") of history."
            }
        }
        .fileExporter(isPresented: $exportingPasswords, document: csvDocument, contentType: .commaSeparatedText, defaultFilename: "Browser Setu Passwords") { result in
            csvDocument = PasswordCSVDocument(text: "")
            if case .success = result { model.notice = "Passwords exported. The file is plain text: delete it when you are done." }
        }
        .confirmationDialog("Export every saved password?", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("Export as Plain Text", role: .destructive) {
                Task {
                    guard await model.requireAuthentication("Export your saved passwords") else { return }
                    csvDocument = PasswordCSVDocument(text: PasswordImport.csv(for: WebLoginVault.list(profile: model.profileName)))
                    exportingPasswords = true
                }
            }
        } message: { Text("The file will hold every password as readable text. Anyone who can open the file can read them. Keep it somewhere private and delete it when you are done.") }
        .confirmationDialog("Delete the file you imported from?", isPresented: $askToDelete, titleVisibility: .visible) {
            Button("Delete the File", role: .destructive) { if let url = lastImportedFile { _ = url.startAccessingSecurityScopedResource(); try? FileManager.default.removeItem(at: url); url.stopAccessingSecurityScopedResource() } }
            Button("Keep It", role: .cancel) {}
        } message: { Text("It holds your old passwords as readable text. If Browser Setu cannot delete it, move it to the Trash yourself.") }
    }
}

struct PasswordCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct BackupSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var exportSheet = false
    @State private var exporting = false
    @State private var document = BackupDocument(data: Data())
    @State private var importing = false
    @State private var restoreData: Data?
    @State private var includePasswords = false

    var body: some View {
        Section("Backup") {
            Button("Export an Encrypted Backup…") { Task { if await model.requireAuthentication("Export a backup of your settings and bookmarks") { exportSheet = true } } }
            Button("Restore from a Backup…") { Task { if await model.requireAuthentication("Restore a backup") { importing = true } } }
            Text("A backup holds your bookmarks and Browser Setu settings, locked with a passphrase you choose. Your saved passwords go in only if you tick that box; cookies and history never do. Save the file in iCloud Drive to keep it safe off this device. Browser Setu cannot recover a forgotten passphrase.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $exportSheet) {
            PassphraseSheet(title: "Export a Backup", confirmLabel: "Create Backup", askTwice: true, action: { passphrase in
                document = BackupDocument(data: try await model.makeBackupAsync(passphrase: passphrase, includePasswords: includePasswords))
                exporting = true
            }, optionTitle: "Include my saved passwords", option: $includePasswords)
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                      defaultFilename: "Browser Setu \(Date().formatted(.iso8601.year().month().day())).bsbackup") { result in
            if case .success = result { model.notice = "Backup saved." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { restoreData = data } else { model.notice = "That file could not be read." }
        }
        .sheet(isPresented: Binding(get: { restoreData != nil }, set: { if !$0 { restoreData = nil } })) {
            PassphraseSheet(title: "Restore a Backup", confirmLabel: "Restore", askTwice: false) { passphrase in
                guard let data = restoreData else { return }
                let result = try await model.restoreBackupAsync(data, passphrase: passphrase)
                model.notice = "Restored \(result.bookmarks) bookmarks and \(result.settings) settings" + (model.lastRestoredPasswords > 0 ? " and \(model.lastRestoredPasswords) passwords." : ".")
                restoreData = nil
            }
        }
    }
}

/// Asks for a passphrase and runs `action`; an error from the action is shown in the sheet.
struct PassphraseSheet: View {
    let title: String
    let confirmLabel: String
    let askTwice: Bool
    let action: (String) async throws -> Void
    /// An extra choice shown under the passphrase (for the backup: whether to include saved passwords).
    var optionTitle: String? = nil
    var option: Binding<Bool>? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var working = false
    @State private var problem: String?

    private var ready: Bool { !first.isEmpty && (!askTwice || first == second) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            SecureField("Passphrase", text: $first)
            if askTwice {
                SecureField("Type it again", text: $second)
                if !second.isEmpty && first != second { Text("The two passphrases do not match.").font(.caption).foregroundStyle(.red) }
            }
            if let optionTitle, let option { Toggle(optionTitle, isOn: option).toggleStyle(.switch) }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmLabel) {
                    working = true
                    Task {
                        do { try await action(first); dismiss() } catch { problem = error.localizedDescription }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(!ready || working)
            }
            if working { ProgressView().controlSize(.small) }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Recovery and About

struct RecoverySection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var confirm = false

    var body: some View {
        if let state = model.recovery {
            Section("Recovery") {
                Label(state.detail, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Start a New Profile…") { confirm = true }
            }
            .confirmationDialog("Start a new profile?", isPresented: $confirm) {
                Button("Move old data aside and start new", role: .destructive) { model.resetUnreadableProfile() }
            } message: {
                Text("Open tabs will close. Your unreadable data is kept in the app’s “recovered” folder, not deleted.")
            }
        }
    }
}

struct AboutSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var showLicences = false

    /// The web engine is the system's WebKit, so its security fixes arrive with system updates; this says which system is running.
    private var engineText: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return "WebKit from macOS \(v.majorVersion).\(v.minorVersion)"
        #else
        return "WebKit from iOS \(v.majorVersion).\(v.minorVersion)"
        #endif
    }

    private var listsText: String {
        let states = model.privacy.configuration.listStates.values
        guard let newest = states.map(\.updatedAt).max() else { return "Built-in rules only" }
        return "\(states.map(\.ruleCount).reduce(0, +)) rules, updated \(newest.formatted(date: .abbreviated, time: .omitted))"
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
            LabeledContent("Build", value: Self.build)
            LabeledContent("Web engine", value: engineText)
            LabeledContent("Privacy lists", value: listsText)
            Text("Browser Setu uses the system’s web engine, so a system update is also how the engine’s security fixes arrive. Updates never change your privacy settings.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Acknowledgements and Licences…") { showLicences = true }
        }
        .sheet(isPresented: $showLicences) { AcknowledgementsSheet() }
    }
}

struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    static var text: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Acknowledgements and Licences").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                Text(Self.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}


/// Add or change one saved password. Showing it needs Touch ID, like copying it.
struct LoginEditor: View {
    let original: WebLogin?
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var site = ""
    @State private var user = ""
    @State private var password = ""
    @State private var revealed = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "Add a Password" : "Edit Password").font(.title3.bold())
            TextField("Website, such as https://example.com", text: $site).textFieldStyle(.roundedBorder).disabled(original != nil)
            TextField("Username or email", text: $user).textFieldStyle(.roundedBorder)
            HStack {
                Group { if revealed { TextField("Password", text: $password) } else { SecureField("Password", text: $password) } }.textFieldStyle(.roundedBorder)
                Button(revealed ? "Hide" : "Show") {
                    Task {
                        if revealed || original == nil { revealed.toggle(); return }
                        if await model.requireAuthentication("Show a saved password") { revealed = true }
                    }
                }
                Button("Generate") { password = PasswordGenerator.make(); revealed = true }
            }
            StrengthMeter(password: password, user: user)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(site.isEmpty || user.isEmpty || password.isEmpty) }
        }
        .padding(20).frame(minWidth: 420)
        .onAppear { if let original { site = original.origin; user = original.user; password = original.password } }
    }

    private func save() {
        let address = site.contains("://") ? site : "https://" + site
        guard let origin = WebLoginOrigin.normalized(address) else { problem = "Use a website that starts with https."; return }
        guard LoginRules.capture(["origin": origin, "user": user, "password": password]) != nil else { problem = "The name or password is too long."; return }
        if let original, original.user != user.trimmingCharacters(in: .whitespaces) { WebLoginVault.forget(original, profile: model.profileName) }
        guard WebLoginVault.save(WebLogin(origin: origin, user: user.trimmingCharacters(in: .whitespaces), password: password), profile: model.profileName) else { problem = "It could not be saved to the Keychain."; return }
        dismiss()
    }
}
