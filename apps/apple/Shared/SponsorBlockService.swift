import Foundation

// The one place the SponsorBlock feature uses the network. It is reached from one place (BrowserModel.sponsorCheck), which has already checked that the feature is on, that the
// person agreed to what it sends, that the tab is not private, and that the site is not switched off. It asks for segments by the FIRST FOUR CHARACTERS of a hash of the video's
// identifier, never the identifier, over https, with no cookies, no cache and no account, to a public server only, and it keeps nothing about the request.

@MainActor
final class SponsorBlockService {
    static let shared = SponsorBlockService()
    static let defaultServer = "https://sponsor.ajay.app"

    /// How a request is made; replaced in tests so nothing touches the network.
    var transport: (URL) async throws -> (Data, Int) = SponsorBlockService.send

    /// An https address of a public server: not a local one, no user name or password, no port that is not 443 unless the person chose one.
    static func validServer(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        return !UserScriptNet.isLocalHost(host)
    }

    /// The request for a video's segments. Only the hash prefix is in it.
    static func requestURL(videoID: String, categories: [String], server: String) -> URL? {
        guard SponsorVideoID.valid(videoID), validServer(server), var parts = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = base + "/api/skipSegments/" + SponsorVideoID.hashPrefix(videoID)
        let list = (try? String(data: JSONEncoder().encode(categories.sorted()), encoding: .utf8)) ?? "[]"
        parts.queryItems = [URLQueryItem(name: "categories", value: list), URLQueryItem(name: "actionTypes", value: "[\"skip\"]")]
        return parts.url
    }

    /// The segments of this video, [] when there are none, nil when the server could not be asked or gave an answer that cannot be used.
    func fetch(videoID: String, categories: [String], server: String) async -> [SponsorSpan]? {
        guard let url = Self.requestURL(videoID: videoID, categories: categories, server: server) else { return nil }
        do {
            let (data, status) = try await transport(url)
            if status == 404 { return [] }
            guard status == 200, data.count <= 1_000_000 else { return nil }
            return Self.parse(data, videoID: videoID, categories: categories)
        } catch {
            return nil
        }
    }

    /// The answer holds the segments of every video that shares the prefix; only this video's are taken, and every number and word in them is checked.
    static func parse(_ data: Data, videoID: String, categories: [String]) -> [SponsorSpan]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        guard let mine = list.first(where: { ($0["videoID"] as? String) == videoID }), let raw = mine["segments"] as? [[String: Any]] else { return [] }
        var out: [SponsorSpan] = []
        for item in raw {
            guard let pair = item["segment"] as? [Any], pair.count == 2, let start = (pair[0] as? NSNumber)?.doubleValue, let end = (pair[1] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite, start >= 0, end > start, end - start >= 0.5, end <= 86_400,
                  let category = item["category"] as? String, categories.contains(category),
                  let uuid = item["UUID"] as? String, uuid.count <= 100 else { continue }
            if let action = item["actionType"] as? String, action != "skip" { continue }
            out.append(SponsorSpan(start: start, end: end, category: category, uuid: uuid))
        }
        out.sort { $0.start < $1.start }
        // Overlapping segments become one, so a skip never lands inside another.
        var merged: [SponsorSpan] = []
        for segment in out {
            if var last = merged.last, segment.start < last.end { last.end = max(last.end, segment.end); merged[merged.count - 1] = last } else { merged.append(segment) }
        }
        return Array(merged.prefix(100))
    }

    private static func send(_ url: URL) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: SameHostOnly(url.host ?? ""), delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A redirect to another website is refused.
    private final class SameHostOnly: NSObject, URLSessionTaskDelegate {
        let host: String
        init(_ host: String) { self.host = host }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.host == host && request.url?.scheme == "https" ? request : nil)
        }
    }
}
