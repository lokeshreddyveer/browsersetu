import Foundation

struct SearchEngine: Identifiable, Equatable {
    let id: String
    let name: String
    /// The search address, with `{}` where the query goes.
    let template: String
}

/// The search engines offered in Settings, and the rules for a custom one.
enum SearchEngines {
    static let presets: [SearchEngine] = [
        SearchEngine(id: "brave", name: "Brave Search", template: "https://search.brave.com/search?q={}"),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q={}"),
        SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q={}"),
        SearchEngine(id: "bing", name: "Bing", template: "https://www.bing.com/search?q={}"),
        SearchEngine(id: "ecosia", name: "Ecosia", template: "https://www.ecosia.org/search?q={}"),
        SearchEngine(id: "startpage", name: "Startpage", template: "https://www.startpage.com/do/search?q={}"),
        SearchEngine(id: "qwant", name: "Qwant", template: "https://www.qwant.com/?q={}"),
        SearchEngine(id: "searxng", name: "SearXNG (searx.be)", template: "https://searx.be/search?q={}"),
    ]

    /// The engine a profile uses until the user picks another.
    static var defaultEngine: SearchEngine { presets[0] }

    /// The preset whose address is exactly `template`, or nil for a custom one.
    static func preset(for template: String) -> SearchEngine? {
        presets.first { $0.template == template }
    }

    /// A custom address that is safe to use, or nil. It must be https, name a host, hold no spaces or control
    /// characters, and contain `{}` exactly once, so the query lands in one place.
    static func validated(_ raw: String) -> String? {
        let template = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty, template.count <= 2048,
              template.components(separatedBy: "{}").count == 2,
              !template.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: template.replacingOccurrences(of: "{}", with: "query")),
              url.scheme?.lowercased() == "https", let host = url.host, host.contains(".") else { return nil }
        return template
    }
}
