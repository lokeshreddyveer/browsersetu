import SwiftUI

/// A website's camera or microphone request, and what happened. Only what the browser itself saw.
struct PermissionEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var origin: String
    var kinds: [String]
    var allowed: Bool
    /// "saved" (a decision remembered earlier), "asked" (you were asked once), "always" (you chose Always Allow).
    var how: String

    var summary: String {
        let what = kinds.joined(separator: " and ")
        switch how {
        case "saved": return allowed ? "Allowed \(what) (saved decision)" : "Blocked \(what) (saved decision)"
        case "always": return "You chose Always Allow for \(what)"
        case "hour": return "You allowed \(what) for an hour"
        case "session": return "You allowed \(what) until Browser Setu is next opened"
        case "asked": return allowed ? "You allowed \(what) this time" : "You declined \(what)"
        default: return "Could not decide \(what)"
        }
    }
}

/// A file type that can run code, or change the Mac's settings, is worth a second thought before it is opened.
enum DownloadSafety {
    static let risky: Set<String> = ["dmg", "pkg", "mpkg", "app", "command", "sh", "bash", "zsh", "csh", "scpt", "scptd", "workflow", "action",
                                     "jar", "exe", "msi", "bat", "cmd", "ps1", "vbs", "scr", "apk", "iso", "terminal", "dylib", "kext",
                                     "mobileconfig", "webloc", "url", "pif", "lnk", "reg", "service", "wflow"]

    static func warning(forFilename name: String, from source: URL?) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard risky.contains(ext) else { return nil }
        let from = source?.host.map { " from \($0)" } ?? ""
        return "“\(name)” is a kind of file that can run code or change settings on this device. Only open it if you trust where it came from\(from)."
    }
}

/// What protects you, what connects out, and what is stored: the facts the browser can state, in one place. It does not show counts of
/// blocked requests, because WebKit does not report them.
struct PrivacyDashboardView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var permissionSites = 0
    @State private var storedSites = 0

    private var privacy: PrivacyController { model.privacy }
    private var host: String? { model.active?.url?.host }

    var body: some View {
        Form {
            Section("Protection") {
                LabeledContent("Status", value: privacy.state(forHost: nil).statusWord)
                LabeledContent("Level", value: privacy.configuration.mode.title)
                LabeledContent("Rules active", value: (privacy.snapshot?.totalRules ?? 0).formatted())
                LabeledContent("Filter lists", value: privacy.standardListsReady ? "Ready" : "Not downloaded yet")
                if let date = privacy.configuration.lastSuccessfulUpdate {
                    LabeledContent("Last updated", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Sites with protection off", value: "\(privacy.configuration.siteExceptions.count)")
            }
            if let host {
                Section("This site") {
                    LabeledContent("Website", value: host)
                    LabeledContent("Connection", value: (model.active?.isSecure ?? false) ? "Encrypted (https)" : "Not encrypted")
                    LabeledContent("Protection", value: privacy.state(forHost: host).statusWord)
                }
            }
            Section("Cleaned for you") {
                LabeledContent("Tracking parameters removed from links", value: "\(model.strippedLinkCount) this session")
                Toggle("Remove tracking parameters from links", isOn: $model.stripTrackingParameters)
            }
            Section {
                Toggle("Search suggestions from \(SearchEngines.preset(for: model.searchTemplate)?.name ?? "your search engine")", isOn: $model.searchSuggestionsEnabled)
                Toggle("Download each site’s icon", isOn: $model.fetchSiteIcons)
                Toggle("Update filter lists automatically", isOn: Binding(get: { privacy.configuration.automaticUpdates }, set: { privacy.setAutomaticUpdates($0) }))
            } header: {
                Text("What can connect out")
            } footer: {
                Text("Besides the sites you open, these are the only things the browser contacts. Nothing is collected or sent about you, and private tabs use none of them.")
            }
            Section("Stored on this device") {
                LabeledContent("Sites with a saved camera or microphone decision", value: "\(permissionSites)")
                LabeledContent("Sites storing data (cookies, caches)", value: "\(storedSites)")
                LabeledContent("Cleared when the browser closes", value: model.clearOnQuit.title)
                #if os(macOS)
                Button("Open Privacy Settings…") { model.sheet = nil; SettingsRouter.open(.privacy) }
                #endif
            }
            Section {
                Text("Blocking happens inside WebKit before a request is sent, so the counts in the shield card are estimates. Websites can still recognise you in other ways, and private browsing is not anonymity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            permissionSites = Set(((try? model.core.listPermissions()) ?? []).map(\.origin)).count
            storedSites = await model.siteData().count
        }
        .accessibilityIdentifier("privacy-dashboard")
    }
}

/// Pop-ups stopped, long redirect chains, risky downloads and pauses, newest first. Permission requests are in the section below it.
struct SecurityEventsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            if model.securityEvents.isEmpty {
                Label("Nothing to report", systemImage: "checkmark.shield").foregroundStyle(.secondary)
            }
            ForEach(model.securityEvents.prefix(30)) { event in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.detail).fontWeight(.medium)
                        Text("\(event.site.isEmpty ? "" : event.site + " · ")\(event.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: event.symbol) }
            }
            if !model.securityEvents.isEmpty { Button("Clear Security Events", role: .destructive) { model.clearSecurityEvents() } }
        } header: {
            Text("Security Events")
        } footer: {
            Text("Things Browser Setu did or noticed to keep you safe. Private tabs are not recorded.")
        }
    }
}

/// The recent camera and microphone requests, and what was decided.
struct PermissionActivitySection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            if model.permissionLog.isEmpty {
                Label("No requests yet", systemImage: "clock").foregroundStyle(.secondary)
            }
            ForEach(model.permissionLog.prefix(25)) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.origin).fontWeight(.medium)
                    Text("\(event.summary) · \(event.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.permissionLog.isEmpty { Button("Clear Activity", role: .destructive) { model.clearPermissionLog() } }
        } header: {
            Text("Recent Permission Activity")
        } footer: {
            Text("Requests the browser saw from websites you opened. Private tabs are not recorded.")
        }
    }
}
