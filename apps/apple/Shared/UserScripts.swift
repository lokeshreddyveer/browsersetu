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

    static let maxScripts = 50
    static let maxBytes = 200_000
    var runsEverywhere: Bool { sites.contains("*") }
    var sitesSummary: String { runsEverywhere ? "Every website" : sites.joined(separator: ", ") }
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
        var name = fallbackName
        var sites: [String] = []
        var runAtStart = false
        if let start = text.range(of: "==UserScript=="), let end = text.range(of: "==/UserScript==", range: start.upperBound..<text.endIndex) {
            for line in text[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
                let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t")).split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count == 2, parts[0].hasPrefix("@") else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                switch parts[0] {
                case "@name": name = value
                case "@match", "@include": if let site = site(fromPattern: value), !sites.contains(site) { sites.append(site) }
                case "@run-at": runAtStart = value == "document-start"
                default: break
                }
            }
        }
        return UserScript(name: String(name.prefix(80)), sites: sites, source: text, runAtStart: runAtStart)
    }
}

extension BrowserModel {
    /// Saves the scripts and gives the engine the ones that are switched on.
    func setUserScripts(_ list: [UserScript]) {
        userScripts = Array(list.prefix(UserScript.maxScripts))
        saveSetting("user_scripts", (try? String(data: JSONEncoder().encode(userScripts), encoding: .utf8)) ?? "[]")
        engine.setUserScripts(effectiveUserScripts)
    }

    /// Turns a script on or off. Turning one on shows what it will be able to do, and asks first.
    func setUserScript(_ script: UserScript, enabled: Bool) async {
        guard script.enabled != enabled else { return }
        if enabled {
            guard await requireAuthentication("Turn on a script that can read and change websites") else { return }
            let where_ = script.runsEverywhere ? "EVERY website you visit" : script.sitesSummary
            let choice = await Dialogs.choose(title: "Turn on “\(script.name)”?",
                                              message: "It will run on \(where_) and can read and change those pages, including what you type there. Only turn it on if you wrote it or trust whoever did. It never runs in private tabs.",
                                              buttons: ["Turn On", "Cancel"])
            guard choice == 0 else { return }
        }
        setUserScripts(userScripts.map { var c = $0; if c.id == script.id { c.enabled = enabled }; return c })
    }

    /// Adds a script or saves changes to one. A script that is on and changed has to be confirmed again.
    func saveUserScript(_ script: UserScript) async {
        var script = script
        guard script.source.utf8.count <= UserScript.maxBytes else { notice = "That script is too long."; return }
        if let existing = userScripts.first(where: { $0.id == script.id }) {
            if existing.enabled && (existing.source != script.source || existing.sites != script.sites) { script.enabled = false }
            setUserScripts(userScripts.map { $0.id == script.id ? script : $0 })
        } else {
            guard userScripts.count < UserScript.maxScripts else { notice = "There is room for \(UserScript.maxScripts) scripts."; return }
            script.enabled = false
            setUserScripts(userScripts + [script])
        }
    }

    func deleteUserScript(_ script: UserScript) async {
        guard await requireAuthentication("Remove a script") else { return }
        setUserScripts(userScripts.filter { $0.id != script.id })
    }
}

/// Settings: the scripts, with what each can touch spelled out.
struct UserScriptsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var editing: UserScript?
    @State private var importing = false

    var body: some View {
        Section {
            if model.userScripts.isEmpty { Label("No scripts yet", systemImage: "curlybraces").foregroundStyle(.secondary) }
            ForEach(model.userScripts) { script in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.name).fontWeight(.medium)
                        Text(script.sitesSummary + (script.inPageWorld ? " · page world" : "")).font(.caption).foregroundStyle(script.runsEverywhere ? .orange : .secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit") { editing = script }.buttonStyle(.borderless)
                    Toggle("On", isOn: Binding(get: { script.enabled }, set: { on in Task { await model.setUserScript(script, enabled: on) } })).labelsHidden()
                }
            }
            Button("New Script…") { editing = UserScript(name: "My script", sites: [], source: "// Runs on the websites you list.\n") }
            Button("Import a .user.js File…") { importing = true }
        } header: {
            Text("User Scripts")
        } footer: {
            Text("A script can read and change the websites you name, and see what you type there, so only add code you trust. Scripts are off until you turn them on, never run in private tabs, and cannot reach anything inside Browser Setu.")
        }
        .sheet(item: $editing) { script in UserScriptEditor(script: script) { saved in Task { await model.saveUserScript(saved) } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  let script = UserScriptFile.parse(text, fallbackName: url.deletingPathExtension().lastPathComponent) else {
                model.notice = "That file could not be read as a script."; return
            }
            editing = script
        }
    }
}

private struct UserScriptEditor: View {
    @State var script: UserScript
    let save: (UserScript) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sitesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Script").font(.headline)
            TextField("Name", text: $script.name)
            TextField("Websites, separated by commas (example.com, * for every website)", text: $sitesText).autocorrectionDisabled()
            Picker("Runs", selection: $script.runAtStart) { Text("When the page has loaded").tag(false); Text("As the page starts").tag(true) }
            Toggle("Run in the page’s own world (advanced)", isOn: $script.inPageWorld)
            if script.inPageWorld {
                Text("In the page’s world the script can see and change the page’s own code, and the page can see the script. Leave this off unless the script needs it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextEditor(text: $script.source).font(.system(.body, design: .monospaced)).frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    script.sites = sitesText.split(whereSeparator: { ",; ".contains($0) }).compactMap { UserScriptFile.site(fromPattern: String($0)) }
                    script.name = script.name.trimmingCharacters(in: .whitespaces)
                    save(script); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(script.name.isEmpty || sitesText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
        .onAppear { sitesText = script.sites.joined(separator: ", ") }
    }
}
