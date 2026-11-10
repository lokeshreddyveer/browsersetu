import SwiftUI
import UniformTypeIdentifiers

/// A script the user wrote or chose to trust, run on the websites they name. Off until they turn it on, never in private tabs, and
/// with no way to call anything inside the browser: it can only act on the page.
struct UserScript: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Where it runs: a website name such as "example.com" (that site and its subdomains), or "*" for every website.
    var sites: [String]
    var source: String
    var enabled = false
    /// Run as the page starts loading, instead of once it has loaded.
    var runAtStart = false
    /// Run in the page's own world, where it can see and change the page's own scripts and variables. Off keeps it in the browser's
    /// private world: it can still change the page's content, but the page cannot see it or tamper with it.
    var inPageWorld = false
    /// The pages it runs on (match patterns and globs, see `UserScriptMatcher`). Empty for a script saved before patterns existed: `sites` then stands in.
    var matches: [String] = []
    var excludes: [String] = []
    var version = ""
    var scriptDescription = ""
    var updateURL = ""
    var downloadURL = ""
    /// What the script's header asked for (@grant), and the websites it says it needs to contact (@connect).
    var grants: [String] = []
    var connects: [String] = []
    /// What the person has allowed it to do. Nothing, until they say so.
    var granted: [UserScriptCapability] = []
    /// Also run inside the frames (ads, embeds, sign-in boxes) of the pages it matches, each judged by its own address.
    var allFrames = false
    /// Run again whenever the page changes its address without loading a new document (a single-page site such as GitHub moving between its pages), if the new address matches.
    var rerunOnNavigation = false
    /// When the script came from an enhancement package (see Enhancements.swift): the package, the item, and why it was switched off by itself (if it was).
    var package = ""
    var packageItem = ""
    var autoDisabledReason = ""

    static let maxScripts = 50
    static let maxBytes = 200_000

    private enum CodingKeys: String, CodingKey {
        case id, name, sites, source, enabled, runAtStart, inPageWorld, matches, excludes, version, scriptDescription, updateURL, downloadURL, grants, connects, granted, allFrames, rerunOnNavigation, package, packageItem, autoDisabledReason
    }

    /// The patterns that decide where it runs.
    var patterns: [String] { matches.isEmpty ? sites.map { $0 == "*" ? "<all_urls>" : $0 } : matches }
    var runsEverywhere: Bool { UserScriptMatcher.coversEverything(patterns) }
    var sitesSummary: String {
        if runsEverywhere { return "Every website" }
        return sites.isEmpty ? patterns.joined(separator: ", ") : sites.joined(separator: ", ")
    }
    /// What the header asks for that is not allowed yet.
    var requestedCapabilities: [UserScriptCapability] {
        let wanted = Set(grants.compactMap { UserScriptCapability.needed(by: $0) })
        return UserScriptCapability.allCases.filter { wanted.contains($0) }
    }
    /// Grants the browser does not provide at all.
    var unsupportedGrants: [String] {
        grants.filter { UserScriptCapability.needed(by: $0) == nil && !UserScriptCapability.free.contains($0) }
    }
    func allows(_ capability: UserScriptCapability) -> Bool { granted.contains(capability) }
}

extension UserScript {
    /// Scripts saved by earlier versions have none of the newer keys: each is optional here, so they keep loading as they were.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), sites: try c.decodeIfPresent([String].self, forKey: .sites) ?? [], source: try c.decode(String.self, forKey: .source))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        runAtStart = try c.decodeIfPresent(Bool.self, forKey: .runAtStart) ?? false
        inPageWorld = try c.decodeIfPresent(Bool.self, forKey: .inPageWorld) ?? false
        matches = try c.decodeIfPresent([String].self, forKey: .matches) ?? []
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        scriptDescription = try c.decodeIfPresent(String.self, forKey: .scriptDescription) ?? ""
        updateURL = try c.decodeIfPresent(String.self, forKey: .updateURL) ?? ""
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL) ?? ""
        grants = try c.decodeIfPresent([String].self, forKey: .grants) ?? []
        connects = try c.decodeIfPresent([String].self, forKey: .connects) ?? []
        granted = try c.decodeIfPresent([UserScriptCapability].self, forKey: .granted) ?? []
        allFrames = try c.decodeIfPresent(Bool.self, forKey: .allFrames) ?? false
        rerunOnNavigation = try c.decodeIfPresent(Bool.self, forKey: .rerunOnNavigation) ?? false
        package = try c.decodeIfPresent(String.self, forKey: .package) ?? ""
        packageItem = try c.decodeIfPresent(String.self, forKey: .packageItem) ?? ""
        autoDisabledReason = try c.decodeIfPresent(String.self, forKey: .autoDisabledReason) ?? ""
    }
}

/// Reads the "==UserScript==" header at the top of a `.user.js` file (the format Greasemonkey and Tampermonkey scripts use).
enum UserScriptFile {
    /// The website a match pattern names: "https://*.example.com/path/*" gives "example.com"; "*://*/*" gives "*".
    static func site(fromPattern pattern: String) -> String? {
        var text = pattern.trimmingCharacters(in: .whitespaces)
        if text == "*" || text == "<all_urls>" { return "*" }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        text = String(text.prefix { $0 != "/" && $0 != ":" })
        if text.hasPrefix("*.") { text.removeFirst(2) }
        text = text.lowercased()
        if text == "*" || text.isEmpty { return text == "*" ? "*" : nil }
        guard text.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil, text.contains(".") else { return nil }
        return text
    }

    static func parse(_ text: String, fallbackName: String) -> UserScript? {
        guard text.utf8.count <= UserScript.maxBytes, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let meta = UserScriptMetadata.parse(text)
        var sites: [String] = []
        for pattern in meta.matches { if let site = site(fromPattern: pattern), !sites.contains(site) { sites.append(site) } }
        var script = UserScript(name: String((meta.name ?? fallbackName).prefix(80)), sites: sites, source: text, runAtStart: meta.runAtStart)
        // Only patterns the browser can honour are kept, so what the person is shown is what will run.
        script.matches = meta.matches.filter { UserScriptMatcher.regexSource(for: $0) != nil }
        // An exclude that cannot be read is kept, not dropped: dropping it would let the script run where the author said it must not. The script is left off instead.
        script.excludes = meta.excludes
        if !UserScriptMatcher.allReadable(script.excludes) {
            script.enabled = false
            script.autoDisabledReason = "A line saying where it must not run could not be read, so it was left off."
        }
        script.version = meta.version
        script.scriptDescription = meta.description
        script.updateURL = meta.updateURL
        script.downloadURL = meta.downloadURL
        script.grants = meta.grants
        script.connects = meta.connects
        script.allFrames = meta.hasHeader && !meta.noFrames && !script.matches.isEmpty
        return script
    }
}

extension BrowserModel {
    func configureUserScriptStorage() {
        userScriptStorage.values = { [weak self] id in self?.userScriptValues[id.uuidString] ?? [:] }
        userScriptStorage.setValue = { [weak self] id, key, value in self?.setScriptValue(id, key, value) ?? false }
    }

    /// One saved value of a script that was given storage. False when it would not fit, or the script is not installed.
    func setScriptValue(_ id: UUID, _ key: String, _ value: String?) -> Bool {
        guard userScripts.contains(where: { $0.id == id }), key.count <= 200 else { return false }
        var values = userScriptValues[id.uuidString] ?? [:]
        values[key] = value
        guard values.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= UserScriptStorage.maxBytes else { return false }
        userScriptValues[id.uuidString] = values.isEmpty ? nil : values
        saveSetting("user_script_values", encodedMap(userScriptValues))
        return true
    }

    /// Saves the scripts and gives the engine the ones that are switched on. Pages already open keep what they were given until they are loaded again; every page
    /// opened from now on, and every frame in it, gets the new set.
    func setUserScripts(_ list: [UserScript]) {
        userScripts = Array(list.prefix(UserScript.maxScripts))
        saveSetting("user_scripts", (try? String(data: JSONEncoder().encode(userScripts), encoding: .utf8)) ?? "[]")
        engine.setUserScripts(effectiveUserScripts)
    }

    private func describe(_ script: UserScript) -> String {
        var lines: [String] = []
        lines.append("Runs on: \(script.runsEverywhere ? "EVERY website you visit" : script.sitesSummary)\(script.allFrames ? ", including frames inside those pages" : "").")
        lines.append(script.inPageWorld ? "It runs in the page’s own world: it can see and change the page’s own code, and the page can see it." : "It runs in its own private world: it can change the page’s content, but the page cannot see or tamper with it.")
        let allowed = script.granted.filter { script.requestedCapabilities.contains($0) }
        if allowed.isEmpty { lines.append("It has no extra permissions.") }
        else { lines.append("Allowed: " + allowed.map(\.title).joined(separator: "; ") + ".") }
        if allowed.contains(.network) { lines.append("It may contact: " + (script.connects.isEmpty ? "nothing listed" : script.connects.joined(separator: ", ")) + ".") }
        return lines.joined(separator: "\n")
    }

    /// Turns a script on or off. Turning one on shows what it will be able to do, and asks first.
    func setUserScript(_ script: UserScript, enabled: Bool) async {
        guard script.enabled != enabled else { return }
        if enabled {
            if let problem = UserScriptSyntax.firstError(in: script.source) { notice = "“\(script.name)” has a mistake on line \(problem.line): \(problem.message)"; return }
            guard await requireAuthentication("Turn on a script that can read and change websites") else { return }
            let choice = await Dialogs.choose(title: "Turn on “\(script.name)”?",
                                              message: describe(script) + "\n\nIt can read and change those pages, including what you type there. Only turn it on if you wrote it or trust whoever did.",
                                              buttons: ["Turn On", "Cancel"])
            guard choice == 0 else { return }
        }
        UserScriptDiagnostics.shared.resetFailures(script.id)
        setUserScripts(userScripts.map { var c = $0; if c.id == script.id { c.enabled = enabled; if enabled { c.autoDisabledReason = "" } }; return c })
    }

    /// Adds a script or saves changes to one. Anything that widens what a script can touch (its code, where it runs, its permissions) switches it off until it
    /// is confirmed again; a permission is only given after it has been shown and confirmed.
    func saveUserScript(_ incoming: UserScript) async {
        var script = incoming
        guard script.source.utf8.count <= UserScript.maxBytes else { notice = "That script is too long."; return }
        // What the header says about permissions, version and update addresses comes from the code itself, so the two can never disagree.
        let meta = UserScriptMetadata.parse(script.source)
        if meta.hasHeader {
            script.grants = meta.grants; script.connects = meta.connects; script.version = meta.version
            script.scriptDescription = meta.description; script.updateURL = meta.updateURL; script.downloadURL = meta.downloadURL
        }
        let requested = Set(script.requestedCapabilities)
        script.granted = script.granted.filter { requested.contains($0) }
        let existing = userScripts.first(where: { $0.id == script.id })
        let fresh = script.granted.filter { !(existing?.granted.contains($0) ?? false) }
        if !fresh.isEmpty {
            var ok = await requireAuthentication("Give a script extra permissions")
            if ok {
                var text = fresh.map { "• \($0.title): \($0.detail)" }.joined(separator: "\n")
                if fresh.contains(.network) { text += "\nIt may contact: " + (script.connects.isEmpty ? "nothing listed" : script.connects.joined(separator: ", ")) + (script.connects.contains("*") ? " (ANY website)" : "") + "." }
                ok = await Dialogs.choose(title: "Give “\(script.name)” these permissions?", message: text, buttons: ["Allow", "Don’t Allow"]) == 0
            }
            if !ok { script.granted = existing?.granted.filter { requested.contains($0) } ?? [] }
        }
        if let existing {
            let widened = existing.source != script.source || existing.matches != script.matches || existing.sites != script.sites || existing.excludes != script.excludes
                || existing.inPageWorld != script.inPageWorld || existing.allFrames != script.allFrames || Set(script.granted).subtracting(existing.granted).isEmpty == false
            if existing.enabled && widened { script.enabled = false }
            setUserScripts(userScripts.map { $0.id == script.id ? script : $0 })
        } else {
            guard userScripts.count < UserScript.maxScripts else { notice = "There is room for \(UserScript.maxScripts) scripts."; return }
            script.enabled = false
            setUserScripts(userScripts + [script])
        }
        if let problem = UserScriptSyntax.firstError(in: script.source) { notice = "Saved, but there is a mistake on line \(problem.line): \(problem.message)" }
        else if existing?.enabled == true && !script.enabled { notice = "“\(script.name)” was changed, so it is off until you turn it on again." }
    }

    func deleteUserScript(_ script: UserScript) async {
        guard await requireAuthentication("Remove a script") else { return }
        userScriptValues[script.id.uuidString] = nil
        saveSetting("user_script_values", encodedMap(userScriptValues))
        UserScriptDiagnostics.shared.clear(script.id)
        setUserScripts(userScripts.filter { $0.id != script.id })
    }

    /// Takes a permission away at once. The script is installed again without it, so every page and frame opened from now on is refused, and a call from a page that
    /// is already open is refused too: the bridge checks the permission each time.
    func revokeCapability(_ capability: UserScriptCapability, from script: UserScript) {
        setUserScripts(userScripts.map { var c = $0; if c.id == script.id { c.granted.removeAll { $0 == capability } }; return c })
    }

    /// Reads a script from an address the person typed (https only), and hands back what was read for them to look over. Nothing is installed by this.
    func fetchScriptToInstall(from address: String) async -> UserScript? {
        do {
            let text = try await UserScriptNet.fetchScript(address)
            let name = URL(string: address)?.deletingPathExtension().deletingPathExtension().lastPathComponent ?? "Script"
            guard var script = UserScriptFile.parse(text, fallbackName: name.isEmpty ? "Script" : name) else { notice = "That could not be read as a script."; return nil }
            if script.downloadURL.isEmpty { script.downloadURL = address }
            return script
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Looks for a newer version of one script, because the person asked. What changes is shown first; a version that runs on more websites or asks for more
    /// than the old one leaves the script off until it is turned on again.
    func checkForUpdate(_ script: UserScript) async {
        guard let address = [script.downloadURL, script.updateURL].first(where: { !$0.isEmpty }) else { notice = "“\(script.name)” has no update address."; return }
        var text: String
        do { text = try await UserScriptNet.fetchScript(address) } catch { notice = error.localizedDescription; return }
        // A file that holds only the header (name.meta.js) says which version is current; it is not the script, and it never replaces the script's code. The code comes
        // from the download address, and if there is none the update stops here.
        if !UserScriptMetadata.hasBody(text) {
            guard !script.downloadURL.isEmpty, script.downloadURL != address else { notice = "The update address for “\(script.name)” only describes the script. It has no download address, so nothing was changed."; return }
            guard UserScriptMetadata.isNewer(text, than: script) else { notice = "“\(script.name)” is up to date."; return }
            do { text = try await UserScriptNet.fetchScript(script.downloadURL) } catch { notice = error.localizedDescription; return }
            guard UserScriptMetadata.hasBody(text) else { notice = "The download address for “\(script.name)” holds no script, so nothing was changed."; return }
        }
        let update = UserScriptUpdate.make(from: text, for: script)
        guard update.isNewer else { notice = "“\(script.name)” is up to date."; return }
        if let problem = UserScriptSyntax.firstError(in: text) { notice = "The new version has a mistake on line \(problem.line), so it was not installed."; return }
        var lines = ["Version \(script.version.isEmpty ? "(none)" : script.version) → \(update.meta.version.isEmpty ? "(none)" : update.meta.version)."]
        if !update.addedPatterns.isEmpty { lines.append("Now also runs on: " + update.addedPatterns.joined(separator: ", ")) }
        if !update.addedCapabilities.isEmpty { lines.append("Now asks for: " + update.addedCapabilities.map(\.title).joined(separator: "; ")) }
        if !update.addedConnects.isEmpty { lines.append("Now contacts: " + update.addedConnects.joined(separator: ", ")) }
        if update.widensFrames { lines.append("Now also runs inside the frames (ads, embeds, sign-in boxes) of those pages.") }
        if update.runsEarlier { lines.append("Now runs before the page’s own scripts.") }
        lines.append(update.needsReapproval ? "Because it asks for more, it will be off until you turn it on again." : "It asks for nothing more than before.")
        guard await requireAuthentication("Update a script") else { return }
        guard await Dialogs.choose(title: "Update “\(script.name)”?", message: lines.joined(separator: "\n"), buttons: ["Update", "Cancel"]) == 0 else { return }
        guard var new = UserScriptFile.parse(text, fallbackName: script.name) else { notice = "The new version could not be read."; return }
        new.id = script.id
        new.name = script.name
        new.inPageWorld = script.inPageWorld
        new.excludes = Array(Set(script.excludes + new.excludes)).sorted()
        let requested = Set(new.requestedCapabilities)
        new.granted = script.granted.filter { requested.contains($0) }
        new.enabled = script.enabled && !update.needsReapproval
        if new.downloadURL.isEmpty { new.downloadURL = script.downloadURL }
        if new.updateURL.isEmpty { new.updateURL = script.updateURL }
        setUserScripts(userScripts.map { $0.id == script.id ? new : $0 })
        notice = new.enabled || !script.enabled ? "“\(script.name)” was updated." : "“\(script.name)” was updated and is off until you turn it on again."
    }

    // MARK: Per site

    /// The scripts that would run on this page: the ones whose patterns match its address, on or off.
    func userScripts(matching url: URL?) -> [UserScript] {
        guard let address = url?.absoluteString, url?.scheme == "http" || url?.scheme == "https" else { return [] }
        return userScripts.filter { UserScriptMatcher.matches(address, patterns: $0.patterns) }
    }

    /// Whether a script is kept off this one website (an exclude for it).
    func scriptIsOff(_ script: UserScript, onHost host: String) -> Bool { script.excludes.contains("*://\(host)/*") }

    func setScript(_ script: UserScript, offOnHost host: String, _ off: Bool) {
        let pattern = "*://\(host)/*"
        setUserScripts(userScripts.map {
            var c = $0
            if c.id == script.id { c.excludes.removeAll { $0 == pattern }; if off { c.excludes.append(pattern) } }
            return c
        })
    }
}

/// Settings: the scripts, with what each can touch spelled out.
struct UserScriptsSection: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var diagnostics = UserScriptDiagnostics.shared
    @State private var editing: UserScript?
    @State private var importing = false
    @State private var linking = false

    var body: some View {
        Section {
            if model.userScripts.isEmpty { Label("No scripts yet", systemImage: "curlybraces").foregroundStyle(.secondary) }
            ForEach(model.userScripts) { script in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(script.name).fontWeight(.medium)
                            if !script.version.isEmpty { Text("v\(script.version)").font(.caption2).foregroundStyle(.secondary) }
                            if let e = diagnostics.entries[script.id], e.errors > 0 { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
                        }
                        Text(script.sitesSummary + (script.inPageWorld ? " · page world" : "") + (script.granted.isEmpty ? "" : " · " + script.granted.map(\.rawValue).joined(separator: ", ")))
                            .font(.caption).foregroundStyle(script.runsEverywhere ? .orange : .secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit") { editing = script }.buttonStyle(.borderless)
                    Toggle("On", isOn: Binding(get: { script.enabled }, set: { on in Task { await model.setUserScript(script, enabled: on) } })).labelsHidden()
                }
                .contextMenu {
                    Button("Edit…") { editing = script }
                    Button("Check for Update") { Task { await model.checkForUpdate(script) } }.disabled(script.downloadURL.isEmpty && script.updateURL.isEmpty)
                    Button("Remove", role: .destructive) { Task { await model.deleteUserScript(script) } }
                }
            }
            Button("New Script…") { editing = UserScript(name: "My script", sites: [], source: "// ==UserScript==\n// @name My script\n// @match https://example.com/*\n// ==/UserScript==\n") }
            Button("Install from a Link…") { linking = true }
            Button("Import a .user.js File…") { importing = true }
        } header: {
            Text("User Scripts")
        } footer: {
            Text("A script can read and change the websites it matches, and see what you type there, so only add code you trust. Scripts are off until you turn them on, never run in private tabs, and cannot reach anything inside the browser: no passwords, files, history or other tabs. Extra abilities (saved values, contacting other websites) are separate permissions, each off until you allow it for that one script.")
        }
        .sheet(item: $editing) { script in UserScriptEditor(script: script) { saved in Task { await model.saveUserScript(saved) } } }
        .sheet(isPresented: $linking) { InstallFromLinkSheet { script in editing = script } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  let script = UserScriptFile.parse(text, fallbackName: url.deletingPathExtension().deletingPathExtension().lastPathComponent) else {
                model.notice = "That file could not be read as a script."; return
            }
            editing = script
        }
    }
}

private struct InstallFromLinkSheet: View {
    @EnvironmentObject var model: BrowserModel
    let open: (UserScript) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install from a link").font(.headline)
            TextField("https://example.com/script.user.js", text: $address)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
                .settingsNoted("Only https links to public websites. The script is downloaded without your cookies, shown to you, and installed switched off.")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Downloading…" : "Download") {
                    working = true
                    Task {
                        let script = await model.fetchScriptToInstall(from: address)
                        working = false
                        if let script { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open(script) } }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 460)
        #endif
    }
}

private struct UserScriptEditor: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var diagnostics = UserScriptDiagnostics.shared
    @State var script: UserScript
    let save: (UserScript) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var matchText = ""
    @State private var excludeText = ""
    @State private var removing = false

    private var saved: Bool { model.userScripts.contains { $0.id == script.id } }
    private func lines(_ text: String) -> [String] { text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var unreadable: [String] { (lines(matchText) + lines(excludeText)).filter { UserScriptMatcher.regexSource(for: $0) == nil } }
    private var declared: [UserScriptCapability] { UserScriptMetadata.parse(script.source).grants.compactMap { UserScriptCapability.needed(by: $0) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Script").font(.headline)
                TextField("Name", text: $script.name)
                if !script.scriptDescription.isEmpty { Text(script.scriptDescription).settingsNote() }
                Text("Runs on these pages (one pattern per line: https://example.com/*, *://*.example.com/*, or just example.com)").settingsNote()
                TextEditor(text: $matchText).font(.system(.callout, design: .monospaced)).frame(height: 70).autocorrectionDisabled()
                Text("Never on these pages (optional)").settingsNote()
                TextEditor(text: $excludeText).font(.system(.callout, design: .monospaced)).frame(height: 44).autocorrectionDisabled()
                if !unreadable.isEmpty { Text("Not understood, and ignored: " + unreadable.joined(separator: ", ")).font(.caption).foregroundStyle(.orange) }
                Picker("Runs", selection: $script.runAtStart) { Text("When the page has loaded").tag(false); Text("As the page starts").tag(true) }
                Toggle("Also in frames inside those pages", isOn: $script.allFrames)
                Toggle("Run again when the page changes address without reloading", isOn: $script.rerunOnNavigation)
                    .settingsNoted("For sites that move between pages without loading them again. The script then runs every time the new address matches, so it should be safe to run more than once.")
                Toggle("Run in the page’s own world (advanced)", isOn: $script.inPageWorld)
                Text(script.inPageWorld
                     ? "In the page’s world the script can see and change the page’s own code, and the page can see the script and what it does. It gets no saved values and cannot contact other websites for you, whatever it asks for. Leave this off unless it must use the page’s own variables."
                     : "In its own world the script can change the page’s content but not the page’s own variables or functions, and the page cannot see it.")
                    .font(.caption).foregroundStyle(script.inPageWorld ? .orange : .secondary)

                permissions
                updates
                diagnosticsView

                Text("Code").settingsNote()
                TextEditor(text: $script.source).font(.system(.body, design: .monospaced)).frame(minHeight: 200)
                HStack {
                    if saved { Button("Remove", role: .destructive) { removing = true } }
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Save") {
                        script.matches = lines(matchText).filter { UserScriptMatcher.regexSource(for: $0) != nil }
                        script.excludes = lines(excludeText)
                        script.sites = script.matches.compactMap { UserScriptFile.site(fromPattern: $0) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                        script.name = script.name.trimmingCharacters(in: .whitespaces)
                        save(script); dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(script.name.isEmpty || lines(matchText).filter { UserScriptMatcher.regexSource(for: $0) != nil }.isEmpty || !unreadable.isEmpty)
                }
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #endif
        .onAppear {
            matchText = script.patterns.map { $0 }.joined(separator: "\n")
            excludeText = script.excludes.joined(separator: "\n")
        }
        .confirmationDialog("Remove “\(script.name)”?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.deleteUserScript(script); dismiss() } }
        } message: { Text("Its saved values are removed too.") }
    }

    @ViewBuilder private var permissions: some View {
        Divider()
        Text("Permissions").font(.subheadline).fontWeight(.semibold)
        if declared.isEmpty && script.unsupportedGrants.isEmpty {
            Text("This script asks for nothing beyond changing the pages it runs on.").settingsNote()
        }
        ForEach(declared) { capability in
            Toggle(isOn: Binding(get: { script.granted.contains(capability) },
                                 set: { on in
                                     if on { if !script.granted.contains(capability) { script.granted.append(capability) } }
                                     else if saved { model.revokeCapability(capability, from: script); script.granted.removeAll { $0 == capability } }
                                     else { script.granted.removeAll { $0 == capability } }
                                 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(capability.title)
                    Text(capability.detail).settingsNote()
                    if capability == .network { Text("Websites: " + (UserScriptMetadata.parse(script.source).connects.isEmpty ? "none listed" : UserScriptMetadata.parse(script.source).connects.joined(separator: ", "))).settingsNote() }
                }
            }
            .disabled(script.inPageWorld)
        }
        if !script.unsupportedGrants.isEmpty {
            Text("Asked for but not available in this browser: " + script.unsupportedGrants.joined(separator: ", ")).settingsNote()
        }
        Text("Nothing here gives a script your passwords, files, history or other tabs; there is no permission for them.").font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private var updates: some View {
        if saved {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.version.isEmpty ? "No version" : "Version \(script.version)").font(.subheadline)
                    Text(script.downloadURL.isEmpty && script.updateURL.isEmpty ? "No update address in the script." : (script.downloadURL.isEmpty ? script.updateURL : script.downloadURL)).settingsNote().lineLimit(1)
                }
                Spacer()
                Button("Check for Update") { Task { await model.checkForUpdate(script); dismiss() } }
                    .disabled(script.downloadURL.isEmpty && script.updateURL.isEmpty)
            }
        }
    }

    @ViewBuilder private var diagnosticsView: some View {
        if saved {
            Divider()
            Text("Diagnostics (this session)").font(.subheadline).fontWeight(.semibold)
            if let e = diagnostics.entries[script.id] {
                Text("Ran \(e.runs) time\(e.runs == 1 ? "" : "s")" + (e.lastRun.map { ", last " + $0.formatted(date: .omitted, time: .standard) } ?? "") + (e.errors > 0 ? " · \(e.errors) error\(e.errors == 1 ? "" : "s")" : "")).font(.caption)
                if let error = e.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                if !e.denied.isEmpty { Text("Refused (no permission): " + e.denied.joined(separator: ", ")).settingsNote() }
                if !e.log.isEmpty { Text(e.log.suffix(8).joined(separator: "\n")).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
            } else {
                Text(script.enabled ? "Has not run yet. Open a page it matches." : "It is off.").settingsNote()
            }
        }
    }
}

/// The scripts that match the page in front, with a switch for each to keep it off this one website. Used by the site menus on the Mac and the iPhone.
struct SiteScriptsList: View {
    @EnvironmentObject var model: BrowserModel
    let url: URL?

    var body: some View {
        let scripts = model.userScripts(matching: url)
        if let host = url?.host, !scripts.isEmpty {
            ForEach(scripts) { script in
                Toggle(isOn: Binding(get: { script.enabled && !model.scriptIsOff(script, onHost: host) },
                                     set: { on in
                                         if on && !script.enabled { Task { await model.setUserScript(script, enabled: true) } }
                                         model.setScript(script, offOnHost: host, !on)
                                     })) {
                    Label(script.name, systemImage: "curlybraces")
                }
            }
        }
    }
}
