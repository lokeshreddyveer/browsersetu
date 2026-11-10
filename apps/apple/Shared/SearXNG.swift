import SwiftUI

/// A SearXNG search engine the person runs or trusts. SearXNG is a "metasearch" site that asks other search engines on your behalf; whoever runs the instance you choose
/// sees every query you send it, so a public instance is no more private than any other search site. The address is kept per profile, suggestions stay off unless asked for,
/// and this browser contacts the instance only when you search (or, if you turn suggestions on, while you type).
enum SearXNG {
    /// What a person must know before choosing an instance.
    static let privacyNote = "Whoever runs a SearXNG instance receives every search you send it, and the instance sends your query on to the search engines it uses. A public instance is not automatically private or trustworthy. For the most privacy, use an instance you run yourself, or one run by someone you trust."

    /// The instance address, tidied: https for any public site, and http only for an address inside your own network (a SearXNG you run at home). No user name, no query
    /// and no fragment; a path is kept (an instance can live under /search-engine). Nil when the address cannot be used.
    static func normalizedInstance(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, !text.contains(where: { $0.isWhitespace }) else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let local = UserScriptNet.isLocalHost(host)
        guard (scheme == "https" && host.contains(".")) || (scheme == "http" && local) else { return nil }
        // An instance's own page names (/search and the like) are not part of its address.
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/search", "/preferences"] where path.hasSuffix(suffix) { path.removeLast(suffix.count) }
        parts.path = path
        parts.scheme = scheme
        parts.host = host
        return parts.url?.absoluteString
    }

    /// The address a search goes to. `GET /search?q=…` is the page every instance offers; the JSON form is often switched off and is not used.
    static func searchTemplate(forInstance instance: String) -> String { instance + "/search?q={}" }

    /// Where suggestions come from, if the person asked for them. https only (the suggestion request is made over https and nothing else), and it may not exist on an instance.
    static func suggestionEndpoint(forInstance instance: String) -> String? { instance.hasPrefix("https://") ? instance + "/autocompleter?q={}" : nil }

    static func instance(fromTemplate template: String) -> String? {
        template.hasSuffix("/search?q={}") ? String(template.dropLast("/search?q={}".count)) : nil
    }

    /// Set by the browser while suggestions from a chosen instance are switched on, so the suggestion code asks that instance and no other.
    nonisolated(unsafe) static var activeTemplate: String?
    nonisolated(unsafe) static var activeSuggestionEndpoint: String?
}

extension BrowserModel {
    /// Uses this instance for searches, if its address is usable. Returns whether it was.
    @discardableResult
    func useSearXNG(instance raw: String) -> Bool {
        guard let instance = SearXNG.normalizedInstance(raw) else { return false }
        searxngInstance = instance
        let template = SearXNG.searchTemplate(forInstance: instance)
        // Written directly: the general check for a custom engine allows https only, and an instance at home is http.
        try? core.setSetting(key: "search_template", value: template)
        objectWillChange.send()
        refreshSearXNGSuggestions()
        return true
    }

    func refreshSearXNGSuggestions() {
        if searxngSuggestions, let instance = SearXNG.instance(fromTemplate: searchTemplate), instance == searxngInstance,
           let endpoint = SearXNG.suggestionEndpoint(forInstance: instance) {
            SearXNG.activeTemplate = searchTemplate
            SearXNG.activeSuggestionEndpoint = endpoint
        } else {
            SearXNG.activeTemplate = nil
            SearXNG.activeSuggestionEndpoint = nil
        }
    }

    /// Opens a search on the instance in a new tab, so the person can see for themselves that it answers.
    func openSearXNGTest() {
        guard let instance = SearXNG.normalizedInstance(searxngInstance), let url = URL(string: SearXNG.searchTemplate(forInstance: instance).replacingOccurrences(of: "{}", with: "browser+setu")) else { return }
        _ = openTab(url: url, isPrivate: false)
    }
}

struct SearXNGSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var text = ""
    @State private var invalid = false

    private var usingIt: Bool { SearXNG.instance(fromTemplate: model.searchTemplate) == model.searxngInstance && !model.searxngInstance.isEmpty }

    var body: some View {
        Section {
            TextField("Your SearXNG address (https://search.example.org)", text: $text).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
                .onSubmit(apply)
            if invalid { Text("That is not an address that can be used: it must be https (or http for a server inside your own network), with no user name or query.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(usingIt ? "Using This Instance" : "Use This Instance", action: apply).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Open a Test Search") { model.openSearXNGTest() }.disabled(model.searxngInstance.isEmpty)
            }
            if usingIt {
                Toggle("Suggest searches from this instance", isOn: $model.searxngSuggestions)
                    .disabled(SearXNG.suggestionEndpoint(forInstance: model.searxngInstance) == nil)
                Text(model.searxngSuggestions
                     ? "While you type, what you type is sent to \(URL(string: model.searxngInstance)?.host ?? "the instance"). Not every instance offers this, and nothing appears if it does not."
                     : "Off. Nothing you type is sent until you search.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("SearXNG")
        } footer: {
            Text(SearXNG.privacyNote)
        }
        .onAppear { text = model.searxngInstance }
    }

    private func apply() { invalid = !model.useSearXNG(instance: text); if !invalid { text = model.searxngInstance } }
}
