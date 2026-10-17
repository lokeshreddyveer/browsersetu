import CryptoKit
import Foundation
import SetuPrivacyCore

/// The only code in the app that talks to the network on its own initiative, and only when the user presses
/// "Update Now" or has switched automatic updates on. It requests nothing but the list URL itself.
protocol ListFetching: Sendable {
    func fetch(_ url: URL, limit: Int) async throws -> Data
}

enum ListUpdateError: LocalizedError, Equatable {
    case notHTTPS, badStatus(Int), tooLarge, notText, insecureRedirect, proxyOn
    var errorDescription: String? {
        switch self {
        case .notHTTPS: "Lists must be downloaded over HTTPS."
        case .badStatus(let code): "The server answered with status \(code)."
        case .tooLarge: "The list is larger than the 8 MB limit."
        case .notText: "The download was not a text filter list."
        case .insecureRedirect: "The server tried to redirect to a non-HTTPS address."
        case .proxyOn: "Lists are not downloaded while a proxy is on, because the download would not go through it. Turn the proxy off to update them."
        }
    }
}

/// No cookies, no cache, no credentials, no referrer, no identifiers. Fixed generic User-Agent.
struct URLSessionListFetcher: ListFetching {
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }
    }

    func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard url.scheme == "https" else { throw ListUpdateError.notHTTPS }
        guard !ProxyState.active else { throw ListUpdateError.proxyOn }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "BrowserSetu-FilterUpdate", "Accept": "text/plain"]
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse {
            if http.url?.scheme != "https" { throw ListUpdateError.insecureRedirect }
            guard http.statusCode == 200 else { throw ListUpdateError.badStatus(http.statusCode) }
            if http.expectedContentLength > Int64(limit) { throw ListUpdateError.tooLarge }
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw ListUpdateError.tooLarge }
        }
        return data
    }
}

/// Validated list texts kept on disk so protection works offline. Bounded in count and total size.
struct ListCache {
    static let maxFiles = 60
    static let maxTotalBytes = 96 * 1024 * 1024
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(for url: String) -> URL {
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".txt")
    }

    func read(_ url: String) -> Data? { try? Data(contentsOf: file(for: url)) }

    func readAll(_ urls: [String]) -> [String: Data] {
        var out: [String: Data] = [:]
        for url in urls { if let data = read(url) { out[url] = data } }
        return out
    }

    /// Atomic: write to a temporary name, then replace, so a crash never leaves a half-written list.
    func write(_ data: Data, for url: String) throws {
        let target = file(for: url)
        let temp = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: target)
        }
    }

    func remove(_ url: String) { try? FileManager.default.removeItem(at: file(for: url)) }

    /// Evicts the oldest files outside `keeping` when over either bound.
    func trim(keeping urls: [String]) {
        let keep = Set(urls.map { file(for: $0).lastPathComponent })
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries = items.compactMap { url -> (URL, Date, Int)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }
        entries.sort { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        var count = entries.count
        for entry in entries where (count > Self.maxFiles || total > Self.maxTotalBytes) && !keep.contains(entry.0.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.2; count -= 1
        }
    }

    var fileCount: Int { (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0 }
}
