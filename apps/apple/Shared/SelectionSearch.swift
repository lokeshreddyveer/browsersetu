import Foundation

/// Searching the words you have selected with any engine you have: the presets, the keyword engines (g, yt, gh…) and your own.
enum SelectionSearch {
    struct Engine: Equatable, Identifiable { var name: String; var template: String; var id: String { template } }

    static func engines(custom: [String: String]) -> [Engine] {
        var seen = Set<String>(), out: [Engine] = []
        func add(_ name: String, _ template: String) { if SearchEngines.validated(template) != nil || template.hasPrefix("https://maps.apple.com"), seen.insert(template).inserted { out.append(Engine(name: name, template: template)) } }
        for p in SearchEngines.presets { add(p.name, p.template) }
        for e in SearchShortcuts.builtIn { add(e.name, e.template) }
        for (keyword, template) in custom.sorted(by: { $0.key < $1.key }) { add(keyword, template) }
        return out
    }

    /// The address for a search, or nil when the words are empty. Selected text is cut to a sensible length and encoded so it stays one value.
    static func url(for text: String, template: String) -> URL? {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty, template.components(separatedBy: "{}").count == 2 else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
        guard let encoded = String(words.prefix(300)).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{}", with: encoded))
    }
}

extension BrowserModel {
    func searchSelection(with engine: SelectionSearch.Engine) {
        Task { @MainActor in
            guard let text = await active?.engine.selectedText(), let url = SelectionSearch.url(for: text, template: engine.template) else { notice = "Select some words first."; return }
            _ = openTab(url: url, isPrivate: active?.isPrivate ?? false)
        }
    }
}
