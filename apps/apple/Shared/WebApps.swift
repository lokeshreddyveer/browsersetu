import SwiftUI

/// A website kept as an app: its own window on the Mac (a tab set apart on the iPhone), with its own sign-ins, and rules for where it may go. It is NOT a separate application
/// file in the Dock; it is a window of Browser Setu, so it updates with Browser Setu and needs no separate signing or installer.
struct WebAppRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var startURL: URL
    /// A small picture of the site's icon, if one was found.
    var iconPNG: Data?
    /// Websites (name without "www.") the app may show. The start site is always one. Anything else opens outside the app.
    var allowedSites: [String]
    /// The identity (cookies and storage) set apart for this app: nothing it keeps is shared with the browser. Empty shares the browser's.
    var container: String
    /// Whether a page may open pop-up windows inside the app. Off, they open outside it (a sign-in that needs a pop-up then needs this on).
    var allowsPopups = false
    var showsNavigation = true
    var openAtLaunch = false
    /// Whether the site may ask to show notifications. The site still has to ask, and the system has its own switch.
    var notifications = false

    static let maxApps = 40

    /// The address is one the app may show.
    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return allowedSites.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// What a page says about itself as an app: the manifest's name, start address and icons, and the page's own title.
struct WebAppMetadata: Decodable {
    struct Icon: Decodable { var src: String; var sizes: String? }
    struct Manifest: Decodable { var name: String?; var short_name: String?; var start_url: String?; var display: String?; var scope: String?; var icons: [Icon]? }
    var title: String?
    var url: String?
    var appName: String?
    var manifest: Manifest?
    var icons: [Icon]?

    /// The name to offer: the manifest's, then the page's own application name, then its title.
    var bestName: String {
        let candidates = [manifest?.name, manifest?.short_name, appName, title]
        return String((candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Web App").prefix(40))
    }

    /// The manifest's start address, if it stays on the same website as the page.
    func startURL(page: URL) -> URL {
        guard let raw = manifest?.start_url, let url = URL(string: raw, relativeTo: page)?.absoluteURL, url.scheme == "https" || url.scheme == "http",
              FaviconStore.key(forHost: url.host) == FaviconStore.key(forHost: page.host) else { return page }
        return url
    }
}

enum WebApps {
    /// The page script that reads the metadata. It reads the page's own head and the manifest it names, with no cookies, and returns a short JSON text.
    static let read = """
    var out = { title: document.title || '', url: location.href, appName: null, manifest: null, icons: [] };
    var meta = document.querySelector('meta[name="application-name"]'); if (meta) out.appName = (meta.content || '').slice(0, 80);
    document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]').forEach(function (l) { if (out.icons.length < 12 && l.href) out.icons.push({ src: l.href, sizes: l.getAttribute('sizes') || '' }); });
    var link = document.querySelector('link[rel~="manifest"]');
    if (link && link.href) {
      try {
        var r = await fetch(link.href, { credentials: 'omit' });
        if (r.ok) {
          var m = JSON.parse((await r.text()).slice(0, 65536));
          out.manifest = { name: m.name, short_name: m.short_name, start_url: m.start_url, display: m.display, scope: m.scope,
                           icons: (m.icons || []).slice(0, 10).map(function (i) { return { src: new URL(i.src, link.href).href, sizes: i.sizes || '' }; }) };
        }
      } catch (e) {}
    }
    return JSON.stringify(out);
    """
}

extension BrowserModel {
    func saveWebApps() { saveSetting("web_apps", (try? String(data: JSONEncoder().encode(webApps), encoding: .utf8)) ?? "[]") }

    func loadWebApps(_ get: (String) -> String?) {
        webApps = (get("web_apps")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([WebAppRecord].self, from: $0) } ?? []
    }

    /// Reads the page in front and makes an app of it. Nothing is installed until the person confirms the name and the choices.
    func webAppDraft(from tab: TabController) async -> WebAppRecord? {
        guard !tab.isPrivate, let page = tab.url, page.scheme == "https" || page.scheme == "http", let key = FaviconStore.key(forHost: page.host) else { return nil }
        var metadata: WebAppMetadata?
        if let raw = await tab.engine.webAppMetadata(), let data = raw.data(using: .utf8) { metadata = try? JSONDecoder().decode(WebAppMetadata.self, from: data) }
        let name = metadata?.bestName ?? (page.host ?? "Web App")
        let start = metadata?.startURL(page: page) ?? page
        let icon = FaviconStore.shared.image(forURL: page.absoluteString, points: 64).flatMap { Self.pngData($0) }
        let id = UUID()
        return WebAppRecord(id: id, name: name, startURL: start, iconPNG: icon, allowedSites: [key], container: "app-" + id.uuidString.prefix(8).lowercased())
    }

    @discardableResult
    func installWebApp(_ draft: WebAppRecord) -> WebAppRecord? {
        guard webApps.count < WebAppRecord.maxApps else { notice = "There is room for \(WebAppRecord.maxApps) web apps."; return nil }
        if let existing = webApps.first(where: { $0.startURL == draft.startURL }) { notice = "“\(existing.name)” is already a web app."; return existing }
        var app = draft
        app.name = String(app.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if app.name.isEmpty { app.name = app.startURL.host ?? "Web App" }
        if let key = FaviconStore.key(forHost: app.startURL.host), !app.allowedSites.contains(key) { app.allowedSites.append(key) }
        if !app.container.isEmpty, !containers.contains(app.container) { setContainers(containers + [app.container]) }
        webApps.append(app)
        saveWebApps()
        return app
    }

    func updateWebApp(_ app: WebAppRecord) {
        guard let index = webApps.firstIndex(where: { $0.id == app.id }) else { return }
        webApps[index] = app
        saveWebApps()
    }

    /// Removes the app. Its sign-ins and storage are deleted too if the person says so.
    func removeWebApp(_ app: WebAppRecord, deleteData: Bool) async {
        webApps.removeAll { $0.id == app.id }
        saveWebApps()
        if deleteData, !app.container.isEmpty { await deleteContainer(app.container) }
    }

    /// Opens the app: a window of its own on the Mac, a tab set apart elsewhere. Both follow the app's rules.
    func openWebApp(_ app: WebAppRecord) {
        #if os(macOS)
        windows.openingWebApp = app
        windows.onNeedWindow?()
        #else
        let tab = openTab(url: app.startURL, isPrivate: false, container: app.container.isEmpty ? nil : app.container)
        tab.webApp = app
        #endif
    }

    func openLaunchWebApps() { for app in webApps where app.openAtLaunch { openWebApp(app) } }

    static func pngData(_ image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }
}

extension TabController {
    /// The app this tab belongs to (set when it was opened from one, and for every tab of an app window).
    var governingWebApp: WebAppRecord? { webApp ?? consentOwner?.webApp }

    /// What an app does with an address it was asked to show: its own sites load; anything else opens outside.
    func webAppDecision(for target: URL, mainFrame: Bool) -> NavDecisionKind? {
        guard let app = governingWebApp, target.scheme == "http" || target.scheme == "https" else { return nil }
        if !mainFrame { return .allow }                                   // frames inside the app's own pages (embeds, sign-in boxes) are the page's business
        return app.allows(target) ? .allow : .external
    }
}

enum NavDecisionKind { case allow, external }

/// Settings › Web Apps.
struct WebAppsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var draft: WebAppRecord?
    @State private var editing: WebAppRecord?

    var body: some View {
        Section {
            if model.webApps.isEmpty { Label("No web apps yet", systemImage: "app.dashed").foregroundStyle(.secondary) }
            ForEach(model.webApps) { app in
                HStack {
                    icon(app)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).fontWeight(.medium)
                        Text(app.startURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { model.openWebApp(app) }.buttonStyle(.borderless)
                    Button("Edit") { editing = app }.buttonStyle(.borderless)
                }
            }
            Button("Install This Page as a Web App…") {
                Task { if let tab = model.active, let found = await model.webAppDraft(from: tab) { draft = found } else { model.notice = "Open a normal page first." } }
            }
        } header: {
            Text("Web Apps")
        } footer: {
            #if os(macOS)
            Text("A web app is a window of Browser Setu for one website, with its own sign-ins and rules for where it may go. It is not a separate program in the Dock, so it updates with Browser Setu. To open one when you log in, have your Mac open Browser Setu at login and choose “Open when Browser Setu starts”.")
            #else
            Text("A web app is a tab set apart for one website, with its own sign-ins and rules for where it may go. It does not appear on the Home Screen: iOS lets a browser add a page to the Home Screen only through the share sheet.")
            #endif
        }
        .sheet(item: $draft) { app in WebAppEditor(app: app, isNew: true) { saved in model.installWebApp(saved) } }
        .sheet(item: $editing) { app in WebAppEditor(app: app, isNew: false) { saved in model.updateWebApp(saved) } }
    }

    @ViewBuilder private func icon(_ app: WebAppRecord) -> some View {
        if let data = app.iconPNG, let image = PlatformImage(data: data) {
            Image(platform: image).resizable().scaledToFit().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Text(String(app.name.prefix(1))).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).frame(width: 28, height: 28)
                .background(Theme.tileColor(for: app.name), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

private struct WebAppEditor: View {
    @EnvironmentObject var model: BrowserModel
    @State var app: WebAppRecord
    let isNew: Bool
    let save: (WebAppRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sites = ""
    @State private var removing = false

    var body: some View {
        Form {
            Section(isNew ? "Install as a Web App" : "Web App") {
                TextField("Name", text: $app.name)
                LabeledContent("Starts at", value: app.startURL.absoluteString)
                TextField("Other sites it may show (example.com, accounts.example.com)", text: $sites).autocorrectionDisabled()
            }
            Section {
                Toggle("Keep its sign-ins and storage separate from the browser", isOn: Binding(get: { !app.container.isEmpty }, set: { on in
                    app.container = on ? (app.container.isEmpty ? "app-" + app.id.uuidString.prefix(8).lowercased() : app.container) : ""
                }))
                Toggle("Allow pop-up windows inside the app", isOn: $app.allowsPopups)
                Toggle("Show back, forward and reload", isOn: $app.showsNavigation)
                #if os(macOS)
                Toggle("Open when Browser Setu starts", isOn: $app.openAtLaunch)
                #endif
                Toggle("Let the site ask to show notifications", isOn: $app.notifications)
            } footer: {
                Text("Links to other websites open outside the app. A sign-in that sends you to another site needs that site listed above (and may need pop-ups on). Notifications also need Browser Setu to be allowed in System Settings.")
            }
            HStack {
                if !isNew { Button("Remove…", role: .destructive) { removing = true } }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Install" : "Save") {
                    let extra = sites.split(whereSeparator: { ", ;".contains($0) }).compactMap { FaviconStore.key(forHost: String($0).lowercased()) }
                    var keep = [FaviconStore.key(forHost: app.startURL.host)].compactMap { $0 }
                    for site in extra where !keep.contains(site) { keep.append(site) }
                    app.allowedSites = keep
                    save(app); dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(app.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
        .onAppear { sites = app.allowedSites.filter { $0 != FaviconStore.key(forHost: app.startURL.host) }.joined(separator: ", ") }
        .confirmationDialog("Remove “\(app.name)”?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove and Delete Its Sign-ins and Data", role: .destructive) { Task { await model.removeWebApp(app, deleteData: true); dismiss() } }
            Button("Remove, Keep Its Data") { Task { await model.removeWebApp(app, deleteData: false); dismiss() } }
        }
    }
}
