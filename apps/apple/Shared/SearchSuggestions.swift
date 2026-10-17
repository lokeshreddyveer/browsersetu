import Foundation

/// Suggestions from the search engine itself, as you type. This is the one place where what is typed leaves the device before the
/// user submits, so it is opt-in and narrow: only for the engines that publish a public suggestions address, never for private
/// tabs, never for anything that looks like a web address, over HTTPS only, with no cookies, no saved cache and a short timeout.
enum SearchSuggestions {
    /// The address that returns suggestions for each built-in engine, or nil for an engine without one (and for custom engines).
    static func endpoint(forSearchTemplate template: String) -> String? {
        switch SearchEngines.preset(for: template)?.id {
        case "brave": "https://search.brave.com/api/suggest?q={}&rich=false"
        case "duckduckgo": "https://duckduckgo.com/ac/?q={}&type=list"
        case "google": "https://suggestqueries.google.com/complete/search?client=firefox&q={}"
        case "bing": "https://api.bing.com/osjson.aspx?query={}"
        case "qwant": "https://api.qwant.com/v3/suggest?q={}&locale=en_US"
        case "searxng": "https://searx.be/autocompleter?q={}"
        default: nil
        }
    }

    /// Whether a typed query is worth asking the engine about.
    static func shouldAsk(for query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 100 else { return false }
        if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("javascript:") || text.hasPrefix("file:") { return false }
        // Something that already reads as an address is a destination, not a question for a search engine.
        if case .url? = resolveInput(input: text, searchTemplate: defaultSearchTemplate()) { return false }
        return true
    }

    static func requestURL(endpoint: String, query: String) -> URL? {
        guard let encoded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))),
              let url = URL(string: endpoint.replacingOccurrences(of: "{}", with: encoded)),
              url.scheme == "https" else { return nil }
        return url
    }

    /// The reply, in the common "OpenSearch" shape: `["query", ["suggestion", …], …]`.
    static func parse(_ data: Data, limit: Int = 6) -> [String] {
        guard data.count <= 64 * 1024, let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [Any]
        if let json = object as? [Any], json.count >= 2, let inner = json[1] as? [Any] {
            list = inner                                   // OpenSearch: ["query", ["a", "b"]]
        } else if let json = object as? [String: Any], let body = json["data"] as? [String: Any], let items = body["items"] as? [Any] {
            list = items.map { ($0 as? [String: Any])?["value"] ?? "" }   // Qwant: {"data": {"items": [{"value": "a"}]}}
        } else if let json = object as? [Any], json.allSatisfy({ $0 is String }) {
            list = json                                    // a plain list of strings (SearXNG)
        } else {
            return []
        }
        var seen = Set<String>(), result: [String] = []
        for item in list {
            let text = ((item as? String) ?? (item as? [String: Any])?["q"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 200, seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
            if result.count >= limit { break }
        }
        return result
    }

    /// Asks the engine. Any failure is silence: the typed text is only ever a hint, never something that has to work.
    static func fetch(endpoint: String, query: String) async -> [String] {
        #if DEBUG
        // Tests never reach out to a real search engine.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return [] }
        #endif
        guard !ProxyState.active, let url = requestURL(endpoint: endpoint, query: query) else { return [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }
}
