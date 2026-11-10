import SwiftUI

/// Settings ▸ Downloads ▸ Providers: the website authorizations media downloads use, per profile. Credentials are entered and removed only here (the media window links to this page); the
/// storage is the existing profile Keychain wrapper, and the entry sheet is the same one the media window used to carry.
struct ProviderSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var editing: MediaProviderID?
    @State private var refresh = 0
    @State private var savedExport: String?

    private let providers: [MediaProviderID] = [.vimeo, .tiktok]

    var body: some View {
        Section("Providers") {
            Text("Some websites let you download your own media through an official API. Authorize them here for this profile (\(model.profileName)); a private tab never uses these. Sites that offer no such route (YouTube, Instagram, Facebook, X, Reddit) have nothing to set up.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(providers) { p in
                let has = ProviderCredentials.token(p, profile: model.profileName) != nil
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.displayName).font(.system(size: 13, weight: .medium))
                        Text(has ? "Authorized" : "Not authorized").font(.caption).foregroundStyle(has ? Color.green : Color.secondary)
                        Spacer()
                        Button(has ? "Replace…" : "Authorize…") { editing = p }.accessibilityIdentifier("settings-provider-\(p.rawValue)-authorize")
                        if has { Button("Remove") { ProviderCredentials.revoke(p, profile: model.profileName); refresh += 1 }.accessibilityIdentifier("settings-provider-\(p.rawValue)-remove") }
                    }
                    Text(blurb(p)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if p == .tiktok, let s = savedExport {
                        HStack {
                            Text(s).font(.caption).foregroundStyle(.secondary)
                            Button("Forget it") { UserDefaults.standard.removeObject(forKey: "bs.tiktok.export." + model.profileName); savedExport = nil }.font(.caption)
                        }
                    }
                }
                .id("\(p.rawValue)-\(refresh)")
            }
        }
        .sheet(item: $editing) { p in
            ProviderTokenSheet(provider: p, profile: model.profileName, saved: { editing = nil; refresh += 1 }, cancel: { editing = nil })
        }
        .onAppear(perform: loadExport)
    }

    private func loadExport() {
        if let d = UserDefaults.standard.dictionary(forKey: "bs.tiktok.export." + model.profileName), let id = d["id"] as? String { savedExport = "A data export request is saved (number \(id)). Check it from Downloads ▸ Collect ▸ Export My TikTok Data." } else { savedExport = nil }
    }

    private func blurb(_ p: MediaProviderID) -> String {
        switch p {
        case .vimeo: "Owner-enabled download links for your own videos. Needs a token with the scopes public, private and video_files, on a plan that includes downloads. Sent only to api.vimeo.com."
        case .tiktok: "Account data export (not single videos). Needs TikTok's approval of the app, an account in a region where TikTok offers it, and a token with a portability scope; TikTok decides eligibility when you request an export."
        default: ""
        }
    }
}

/// Settings ▸ Downloads ▸ Media: how the browser notices a page's media, and the languages chosen when a stream offers several. (A default quality is deliberately not offered: what is available
/// differs from stream to stream, so a quality is always chosen for the stream in front.)
struct MediaSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @AppStorage(MediaPageObserver.defaultsKey) private var watchPages = true
    @AppStorage(ResourceDetectionSettings.enabledKey) private var detect = true
    @AppStorage(ResourceDetectionSettings.hiddenKey) private var hiddenRaw = ""

    var body: some View {
        Section("Downloads on a page") {
            Toggle("Show what a page offers to download", isOn: $detect).accessibilityIdentifier("settings-detect-resources")
                .settingsNoted("Reads the addresses of a page's links, nothing else, a moment after it loads, and shows a small indicator for each kind of download. Nothing is fetched or downloaded until you choose it.")
            if detect {
                ForEach(ResourceCategory.allCases) { c in
                    Toggle(c.title, isOn: Binding(get: { !ResourceDetectionSettings.parse(hiddenRaw).contains(c) },
                                                  set: { on in var h = ResourceDetectionSettings.parse(hiddenRaw); if on { h.remove(c) } else { h.insert(c) }; hiddenRaw = h.map(\.rawValue).sorted().joined(separator: ",") }))
                        .accessibilityIdentifier("settings-detect-\(c.rawValue)")
                }
            }
        }
        Section("External extractor") { ExtractorSettingsView() }
        Section("Media processing") { ProcessingToolSettingsView() }
        Section("Permissions for video tools") {
            ConsentList()
        }
        Section("Media") {
            Toggle("Watch pages for media", isOn: $watchPages).accessibilityIdentifier("settings-watch-media")
                .settingsNoted("Lets the browser notice a page's players as they load, so the media indicator in the toolbar and the list are ready. It reads addresses and sizes only. Takes effect for pages opened afterwards.")
            LabeledContent("Preferred audio language") {
                TextField("e.g. en", text: Binding(get: { model.mediaPreferences.audioLanguage }, set: { model.mediaPreferences.audioLanguage = String($0.prefix(8)) })).frame(width: 80)
            }
            LabeledContent("Subtitle language") {
                TextField("none", text: Binding(get: { model.mediaPreferences.subtitleLanguage }, set: { model.mediaPreferences.subtitleLanguage = String($0.prefix(8)) })).frame(width: 80)
            }
            Text("Used as the starting choice when a stream offers several audio or subtitle languages. Subtitles are saved as separate files.").settingsNote()
            HStack(spacing: 4) {
                Text("MP3 encoding uses LAME (LGPL).").font(.system(size: 11)).foregroundStyle(.secondary)
                if let u = URL(string: "https://lame.sourceforge.io") { Link("lame.sourceforge.io", destination: u).font(.system(size: 11)) }
            }
        }
    }
}

/// Settings ▸ Search: the preference that used to be a switch in the Library menu. The command to search from the menu bar is still in the command palette.
struct MenuBarSearchSettingsSection: View {
    @State private var on = MenuBarSearch.shared.isOn
    var body: some View {
        Section("Menu bar") {
            Toggle("Search from the menu bar (Control-Option-Space)", isOn: Binding(get: { on }, set: { on = $0; MenuBarSearch.shared.setOn($0) }))
        }
    }
}


/// What has been allowed for this profile, with a way to take each permission back. A one-time permission is never listed: it is spent by the action it was for.
struct ConsentList: View {
    @EnvironmentObject var model: BrowserModel
    @State private var tick = 0
    var body: some View {
        let grants = { _ = tick; return MediaConsentStore.shared.grants(profile: model.profileName) }()
        if grants.isEmpty {
            Text("Nothing is allowed yet. You are asked the first time a video tool needs it.").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("consent-empty")
        }
        ForEach(Array(grants.enumerated()), id: \.offset) { _, g in
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.purpose.title).font(.system(size: 12.5))
                    Text(scope(g.scope)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revoke") { MediaConsentStore.shared.revoke(g.purpose, profile: model.profileName); tick += 1 }.controlSize(.small).accessibilityIdentifier("consent-revoke")
            }
        }
        Text("Permission lets Browser Setu do these things itself. It does not change what a website or content owner allows.").settingsNote()
    }
    private func scope(_ s: MediaConsentScope) -> String { switch s { case .once: "Once"; case .site(let h): "On \(h)"; case .profile: "Everywhere in this profile" } }
}


/// Settings › Media › External extractor: off until the person chooses a program. Nothing is installed or updated by the browser.
struct ExtractorSettingsView: View {
    @AppStorage(ExtractorSettings.enabledKey) private var enabled = false
    @AppStorage(ExtractorSettings.pathKey) private var path = ""
    @State private var health: ExtractorHealth?
    @State private var checking = false

    @AppStorage(ExtractorSettings.bundledKey) private var useBundled = true

    var body: some View {
        // The media tools Browser Setu installs for you (or ships in the app): status, install, update, repair, remove.
        ManagedMediaToolsSection(useBundled: $useBundled)
        Toggle("Use my own extractor program instead (advanced)", isOn: $enabled).accessibilityIdentifier("extractor-enabled")
            .onChange(of: enabled) { _, _ in check() }
        if enabled {
            LabeledContent("Program") {
                HStack {
                    Text(path.isEmpty ? "None chosen" : path).font(.system(size: 11.5)).foregroundStyle(path.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle).accessibilityIdentifier("extractor-path")
                    Button("Choose…") { choose() }.controlSize(.small).accessibilityIdentifier("extractor-choose")
                    if !path.isEmpty { Button("Remove") { path = ""; enabled = false; health = nil }.controlSize(.small).accessibilityIdentifier("extractor-remove") }
                }
            }
            if !path.isEmpty {
                HStack(spacing: 6) {
                    if checking { ProgressView().controlSize(.small) }
                    Text(healthText).font(.system(size: 11.5)).foregroundStyle(health?.ok == true ? Color.green : Color.secondary).accessibilityIdentifier("extractor-health")
                    Button("Check") { check() }.controlSize(.small)
                }
            }
            if ExternalExtractor.isSandboxed { Button("Open Scripts Folder") { if let u = ExternalExtractor.scriptsFolder { NSWorkspace.shared.open(u) } }.controlSize(.small) }
            Text("The program is third-party software that you choose and keep up to date; this browser does not install or update it. When you allow it for a video, it is started on this Mac with that video's web address and nothing else (no cookies, sign-ins or other pages), and it may contact websites itself. It runs with your Mac permissions. It must print the video's formats as JSON in the form yt-dlp's --dump-single-json uses. It is never used in private tabs.").settingsNote()
        }
    }
    private var healthText: String {
        if let h = health { return h.ok ? "Ready · version \(h.version ?? "?")" : (h.problem ?? "Not usable") }
        return "Not checked yet"
    }
    private func check() {
        guard enabled, !path.isEmpty else { return }
        checking = true
        let p = path
        Task { let h = await ExternalExtractor.health(path: p); await MainActor.run { health = h; checking = false } }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the extractor program or script"
        if ExternalExtractor.isSandboxed { panel.directoryURL = ExternalExtractor.scriptsFolder }
        guard panel.runModal() == .OK, let u = panel.url else { return }
        path = u.path; check()
    }
}


/// Settings › Media › Advanced media downloads: the managed install of the extractor. Installing needs the person's confirmation; it never happens on its own after they decline.
struct ManagedMediaToolsSection: View {
    @StateObject private var store = MediaToolsStore.shared
    @Binding var useBundled: Bool
    @State private var confirmInstall = false
    @State private var confirmRemove = false

    private var m: BundledToolManifest? { store.manifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let m, m.isInstallable || store.isReady {
                LabeledContent("Advanced media downloads") { statusView(m) }.accessibilityIdentifier("media-tools-status")
                if case .working(let f, _) = store.phase { ProgressView(value: f).accessibilityLabel("Installing media tools").accessibilityValue("\(Int(f * 100)) percent").accessibilityIdentifier("media-tools-progress") }
                HStack {
                    switch store.phase {
                    case .notInstalled:
                        Button("Install…") { confirmInstall = true }.accessibilityIdentifier("media-tools-install")
                    case .failed:
                        Button("Retry") { confirmInstall = true }.accessibilityIdentifier("media-tools-install")
                        Button("Remove…") { confirmRemove = true }.accessibilityIdentifier("media-tools-remove")
                    case .updateAvailable:
                        Button("Update…") { confirmInstall = true }.accessibilityIdentifier("media-tools-update")
                        Button("Remove…") { confirmRemove = true }.accessibilityIdentifier("media-tools-remove")
                    case .working:
                        Button("Cancel") { store.cancel() }.accessibilityIdentifier("media-tools-cancel")
                    case .ready:
                        Button("Repair…") { confirmInstall = true }.accessibilityIdentifier("media-tools-repair")
                        Button("Remove…") { confirmRemove = true }.accessibilityIdentifier("media-tools-remove")
                    case .checking: ProgressView().controlSize(.small)
                    }
                }.controlSize(.small)
                Toggle("Use these tools to find a video's formats", isOn: $useBundled).accessibilityIdentifier("extractor-bundled")
                Text("It runs on this Mac only when you ask for a video's formats and allow it for that site. It may contact websites itself. It is never used in private tabs, and it is only ever replaced when you choose Update here.").settingsNote()
                let solver = JSSolver.report()
                LabeledContent("YouTube compatibility") {
                    if !useBundled {
                        Text("Not in use: the bundled yt-dlp is switched off").foregroundStyle(.secondary)       // the solver belongs to the bundled yt-dlp; a yt-dlp you chose never receives it
                    } else {
                        switch JSChallengeProvider.status() {
                        case .builtIn(let v): Text("Built in · JavaScript solver \(v), sandboxed").foregroundStyle(.secondary)
                        case .unavailable(let why): Text("Built-in solver unavailable: \(why.summary)").foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("js-provider-status").help(useBundled ? solver.diagnostics : "A yt-dlp you chose yourself is never given Browser Setu's solver.")
                Text("Some YouTube videos need a small JavaScript puzzle solved before their addresses are known. Browser Setu does it with a helper built into the app that cannot reach the internet, your files or your browsing data. If it is ever unavailable, downloads still work but some YouTube formats may be missing. A managed fallback is planned and is not part of this release. Other websites do not need any of this, and no website is guaranteed to work.").font(.caption).foregroundStyle(.secondary)
                Text("Components: \(m.name) \(m.version) (Unlicense source; the packaged program combines Python, OpenSSL, curl-impersonate and other open-source parts under their own licences, including GPL-3.0-or-later and LGPL). Licence texts are in the package.").settingsNote()
            } else {
                Text("Advanced media downloads are not available in this release yet. Ordinary files, streams and torrents are not affected, and you can still point Browser Setu at a program you installed yourself.").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("extractor-bundled-absent")
            }
        }
        .onAppear { store.refresh() }
        .confirmationDialog(dialogTitle, isPresented: $confirmInstall) {
            Button(dialogButton) { store.install() }
            Button("Not Now", role: .cancel) {}
        } message: { Text(dialogMessage) }
        .confirmationDialog("Remove the media tools?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.remove() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your downloads and settings are not touched. You can install them again at any time.") }
    }

    private var size: String { store.sizeSummary.map { " (\($0))" } ?? "" }
    private var dialogTitle: String {
        switch store.phase { case .ready: "Repair advanced media downloads?"; case .updateAvailable: "Update advanced media downloads?"; case .failed: "Try installing again?"; default: "Install advanced media downloads?" }
    }
    private var dialogButton: String {
        switch store.phase { case .ready: "Download and Repair\(size)"; case .updateAvailable: "Download and Update\(size)"; default: "Download and Install\(size)" }
    }
    private var dialogMessage: String {
        let name = "\(m?.name ?? "The extractor") \(m?.version ?? "")"
        switch store.phase {
        case .ready: return "Browser Setu downloads \(name) again, checks it, and replaces the installed copy only if every check passes."
        case .updateAvailable: return "Browser Setu downloads \(name), checks it, and switches to it only if every check passes. The current version keeps working until then."
        case .failed: return "Browser Setu downloads \(name) again and checks it. Nothing is installed unless every check passes."
        default: return "Browser Setu downloads \(name) from its official release page, checks it against a fingerprint built into this app, and keeps it in its own folder. No administrator password is needed."
        }
    }

    @ViewBuilder private func statusView(_ m: BundledToolManifest) -> some View {
        switch store.phase {
        case .checking: Text("Checking…").foregroundStyle(.secondary)
        case .notInstalled: Text(store.choice == .declined ? "Not installed" : "Not installed").foregroundStyle(.secondary)
        case .working(let f, let t): Text("\(t) \(Int(f * 100))%").foregroundStyle(.secondary)
        case .ready(let v): Text("Installed · \(m.name) \(v)").foregroundStyle(.secondary)
        case .failed(let why): Text(why).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .updateAvailable(let installed): Text("Update available · installed \(installed), new \(m.version)").foregroundStyle(.secondary)
        }
    }
}


/// Settings › Downloads › Media processing: the optional tool that joins WebM picture and sound and takes sound out of WebM/Opus files. Installed on request, by the same verified installer.
struct ProcessingToolSettingsView: View {
    @StateObject private var store = MediaToolsStore.ffmpeg
    @State private var confirmInstall = false
    @State private var confirmRemove = false
    private var m: BundledToolManifest? { store.manifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Joining and converting") { status }.accessibilityIdentifier("processing-tools-status")
            if case .working(let f, _) = store.phase { ProgressView(value: f).accessibilityLabel("Installing the media processing tool").accessibilityValue("\(Int(f * 100)) percent") }
            HStack {
                switch store.phase {
                case .notInstalled: if m?.isInstallable == true { Button("Install…") { confirmInstall = true }.accessibilityIdentifier("processing-tools-install") }
                case .failed: Button("Retry") { confirmInstall = true }.accessibilityIdentifier("processing-tools-install"); Button("Remove…") { confirmRemove = true }
                case .updateAvailable: Button("Update…") { confirmInstall = true }; Button("Remove…") { confirmRemove = true }
                case .working: Button("Cancel") { store.cancel() }
                case .ready: Button("Repair…") { confirmInstall = true }; Button("Remove…") { confirmRemove = true }.accessibilityIdentifier("processing-tools-remove")
                case .checking: ProgressView().controlSize(.small)
                }
            }.controlSize(.small)
            Text("Needed to join the separate picture and sound of WebM videos (the highest qualities of many sites) and to make M4A or MP3 from WebM or Opus audio. It works only on files on this Mac, never uses the network, and is installed only when you ask.").settingsNote()
        }
        .onAppear { store.refresh() }
        .confirmationDialog(store.phase.isFailed ? "Try installing again?" : "Install the media processing tool?", isPresented: $confirmInstall) {
            Button("Download and Install\(store.sizeSummary.map { " (\($0))" } ?? "")") { store.install() }
            Button("Not Now", role: .cancel) {}
        } message: { Text("Browser Setu downloads FFmpeg \(m?.version ?? "") from its release page, checks it against a fingerprint built into this app, and keeps it in its own folder. No administrator password is needed.") }
        .confirmationDialog("Remove the media processing tool?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.remove() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Downloads and settings are not touched. You can install it again at any time.") }
    }

    @ViewBuilder private var status: some View {
        switch store.phase {
        case .checking: Text("Checking…").foregroundStyle(.secondary)
        case .notInstalled: Text(m?.isInstallable == true ? "Not installed" : "Not available in this build yet").foregroundStyle(.secondary)
        case .working(let f, let t): Text("\(t) \(Int(f * 100))%").foregroundStyle(.secondary)
        case .ready(let v): Text("Installed · FFmpeg \(v)").foregroundStyle(.secondary)
        case .failed(let why): Text(why).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .updateAvailable(let i): Text("Update available · installed \(i)").foregroundStyle(.secondary)
        }
    }
}
