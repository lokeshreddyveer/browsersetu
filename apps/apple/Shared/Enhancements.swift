import SwiftUI

// Website-specific enhancements as optional packages. A package is data: a website, and a few small scripts for pages of that website, each saying where it runs and what it asks for.
// Installing one only adds an ordinary user script (off, with no extra permission), so everything the user scripts already guarantee holds here too: nothing runs until it is turned on
// and confirmed, a script cannot reach anything inside the browser, permissions are given one at a time, and it is never run in a private tab. Nothing about any website lives in
// the browser's own code: the knowledge of a site's pages is in its package, and an enhancement that keeps failing is switched off by itself.

struct EnhancementItem: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var summary: String
    var matches: [String]
    var excludes: [String] = []
    var runAtStart = false
    var grants: [String] = []
    var connects: [String] = []
    var source: String
}

struct EnhancementPackage: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// The one website the package is for (and its subdomains). No script in it may match anywhere else.
    var domain: String
    var version: Int
    var summary: String
    var items: [EnhancementItem]
}

enum Enhancements {
    static let maxSourceBytes = 30_000
    private static let allowedGrants: Set<String> = ["GM_xmlhttpRequest", "GM_getValue", "GM_setValue", "GM_addStyle", "GM_log", "none"]

    private static func slug(_ text: String) -> Bool { !text.isEmpty && text.count <= 40 && text.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } }

    /// Whether a match pattern stays on the package's website: its host (or, for a /regex/, its text) names the domain and nothing wider.
    static func pattern(_ pattern: String, staysOn domain: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard UserScriptMatcher.regexSource(for: p) != nil else { return false }
        if p.hasPrefix("/"), p.hasSuffix("/"), p.count > 2 { return p.contains(domain.replacingOccurrences(of: ".", with: "\\.")) && !p.contains(".*\\.") }
        guard let range = p.range(of: "://") else { return false }
        let rest = String(p[range.upperBound...])
        let host = String(rest.prefix { $0 != "/" }).lowercased()
        return host == domain || host == "*." + domain || host.hasSuffix("." + domain) && !host.contains("*")
    }

    /// A package the browser will accept: a website of its own, scripts that stay on it, only the small set of abilities, a size limit, and valid code.
    static func validate(_ package: EnhancementPackage) -> [String] {
        var problems: [String] = []
        if !slug(package.id) { problems.append("the package name is not valid") }
        if package.domain.isEmpty || !package.domain.contains(".") || package.domain.contains("/") || package.domain.contains("*") { problems.append("the website is not valid") }
        if package.items.isEmpty || package.items.count > 20 { problems.append("a package holds between 1 and 20 enhancements") }
        for item in package.items {
            if !slug(item.id) { problems.append("\(item.id): the name is not valid") }
            if item.matches.isEmpty { problems.append("\(item.id): it matches no pages") }
            for m in item.matches + item.excludes where !pattern(m, staysOn: package.domain) { problems.append("\(item.id): “\(m)” is not on \(package.domain)") }
            if !Set(item.grants).isSubset(of: allowedGrants) { problems.append("\(item.id): asks for an ability that packages cannot have") }
            for host in item.connects where UserScriptNet.isLocalHost(host) || host == "*" { problems.append("\(item.id): may not contact “\(host)”") }
            if item.source.utf8.count > maxSourceBytes { problems.append("\(item.id): the code is too long") }
            if let error = UserScriptSyntax.firstError(in: item.source) { problems.append("\(item.id): a mistake on line \(error.line): \(error.message)") }
        }
        return problems
    }

    /// A package from JSON text (the form a future downloadable package would take), or nil if it is not valid.
    static func parse(_ data: Data) -> EnhancementPackage? {
        guard data.count <= 400_000, let package = try? JSONDecoder().decode(EnhancementPackage.self, from: data), validate(package).isEmpty else { return nil }
        return package
    }

    static var bundled: [EnhancementPackage] { [GitHubEnhancements.package].filter { validate($0).isEmpty } }
}

extension BrowserModel {
    func enhancementScript(package: EnhancementPackage, item: EnhancementItem) -> UserScript? {
        userScripts.first { $0.package == package.id && $0.packageItem == item.id }
    }

    /// Adds one enhancement as a user script that is OFF and has been given nothing. Turning it on, and any permission it asks for, are confirmed the usual way.
    func installEnhancement(package: EnhancementPackage, item: EnhancementItem) async {
        guard Enhancements.validate(package).isEmpty, package.items.contains(item), enhancementScript(package: package, item: item) == nil else { return }
        var script = UserScript(name: "\(package.name): \(item.name)", sites: [package.domain], source: item.source, runAtStart: item.runAtStart)
        script.matches = item.matches
        script.excludes = item.excludes
        script.rerunOnNavigation = true          // the sites these are for move between pages without reloading; every item is written to be safe to run again
        script.grants = item.grants
        script.connects = item.connects
        script.version = String(package.version)
        script.scriptDescription = item.summary
        script.package = package.id
        script.packageItem = item.id
        await saveUserScript(script)
    }

    func removeEnhancement(package: EnhancementPackage, item: EnhancementItem) async {
        if let script = enhancementScript(package: package, item: item) { await deleteUserScript(script) }
    }

    /// An enhancement that fails over and over is switched off, and says why. Only ones that came from a package: a script the person wrote is theirs to manage.
    func autoDisableFailingEnhancement(_ id: UUID) {
        guard let script = userScripts.first(where: { $0.id == id }), !script.package.isEmpty, script.enabled else { return }
        let reason = "It failed \(UserScriptDiagnostics.failureLimit) times in ten minutes, so it was switched off. The website's pages may have changed."
        setUserScripts(userScripts.map { var c = $0; if c.id == id { c.enabled = false; c.autoDisabledReason = reason }; return c })
        notice = "“\(script.name)” was switched off: it kept failing."
    }
}

struct EnhancementsSection: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var diagnostics = UserScriptDiagnostics.shared

    var body: some View {
        Section {
            ForEach(Enhancements.bundled) { package in
                DisclosureGroup {
                    ForEach(package.items) { item in row(package, item) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(package.name) · \(package.domain)").fontWeight(.medium)
                        Text(package.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Website Enhancements")
        } footer: {
            Text("Optional extras for one website, made as small scripts. Installing one adds it switched off; you turn it on and confirm it, and any extra permission (such as contacting another website) is asked for separately. They are not part of the browser, never run in private tabs, and one that keeps failing is switched off by itself.")
        }
        .onAppear { UserScriptDiagnostics.shared.onRepeatedFailure = { [weak model] id in model?.autoDisableFailingEnhancement(id) } }
    }

    @ViewBuilder private func row(_ package: EnhancementPackage, _ item: EnhancementItem) -> some View {
        let script = model.enhancementScript(package: package, item: item)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(item.summary).font(.caption).foregroundStyle(.secondary)
                    if !item.connects.isEmpty { Text("Asks to contact: " + item.connects.joined(separator: ", ")).font(.caption2).foregroundStyle(.orange) }
                }
                Spacer()
                if let script {
                    Toggle("On", isOn: Binding(get: { script.enabled }, set: { on in Task { await model.setUserScript(script, enabled: on) } })).labelsHidden()
                    Button("Remove") { Task { await model.removeEnhancement(package: package, item: item) } }.buttonStyle(.borderless)
                } else {
                    Button("Install") { Task { await model.installEnhancement(package: package, item: item) } }.buttonStyle(.borderless)
                }
            }
            if let script, !script.autoDisabledReason.isEmpty { Text(script.autoDisabledReason).font(.caption).foregroundStyle(.orange) }
            if let script, script.version != String(package.version) { Text("A newer version is available; remove and install it again.").font(.caption2).foregroundStyle(.secondary) }
            if let script, let entry = diagnostics.entries[script.id], entry.errors > 0 { Text("\(entry.errors) error\(entry.errors == 1 ? "" : "s") this session").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
