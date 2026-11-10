import Foundation

/// DX-12: what a repository, model or dataset provider hands the download system. A provider only DESCRIBES files (name, size, address, checksum when the service states one);
/// the bytes always travel through the ordinary HTTP engine, the ordinary queue and the ordinary collections.
struct ProviderFile: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case asset, sourceArchive, repoFile, lfsFile, object, artifact }
    var id: String                      // stable identity inside its collection ("asset:123", "file:path/in/repo")
    var name: String                    // file name only
    var folders: [String] = []          // path below the collection
    var size: Int64?
    var sha256: String?                 // only when the SERVICE states it (never computed from the download itself)
    var checksumSource: String?         // where that checksum came from ("GitHub digest", "LFS object id", "SHA256SUMS")
    var url: URL                        // never carries a credential
    var headers: [String: String] = [:] // non-secret request headers (Accept)
    var kind: Kind = .repoFile
    var needsAccount: Bool = false      // the address only works with the person's token (a private repository)
    var note: String?
    var prerelease: Bool = false
    var group: String?                  // the release / revision this belongs to
    var platform: ProviderPlatform = .unknown
    var relativePath: String { (folders + [name]).joined(separator: "/") }
}

/// What a file is for. Used for recommendations only: a recommendation is made only when it is not a guess.
struct ProviderPlatform: Equatable, Sendable {
    enum OS: String, Sendable { case mac, windows, linux, other, unknown }
    enum Arch: String, Sendable { case arm64, x86_64, universal, unknown }
    var os: OS
    var arch: Arch
    static let unknown = ProviderPlatform(os: .unknown, arch: .unknown)
}

struct ProviderListing: Equatable, Sendable {
    var title: String                   // "owner/repo — v1.2.0"
    var source: String                  // collection source key: "github:owner/repo@tag", "hf:owner/model@commit"
    var files: [ProviderFile]
    var revision: String?               // resolved commit (Hugging Face) or tag
    var notices: [String] = []          // plain sentences: gated, truncated, rate limited…
    var truncated = false
    var releaseNames: [String] = []     // GitHub: the releases that can be chosen
}

enum ProviderError: Error, Equatable, LocalizedError {
    case unsupportedAddress
    case notFound
    case unauthorized(host: String, hadToken: Bool)
    case forbidden(String)
    case gated
    case rateLimited(retryAfter: TimeInterval?, host: String)
    case badResponse(String)
    case tooLarge
    case expiredLink
    case network(String)
    case notEnoughSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedAddress: "That address is not one this feature understands."
        case .notFound: "That repository, release or model was not found. If it is private, add an access token for the service first."
        case .unauthorized(let host, let had): had ? "\(host) did not accept the saved access token. Replace it in Settings → Downloads → Accounts." : "\(host) needs an access token for this. Add one in Settings → Downloads → Accounts."
        case .forbidden(let why): why.isEmpty ? "The service refused the request." : "The service refused the request: \(why)"
        case .gated: "This model or dataset is gated. Request access on its web page (in the browser), then try again; Browser Setu does not work around gates."
        case .rateLimited(let after, let host):
            if let after { "\(host) is limiting requests. Try again in about \(Self.wait(after)). Adding an access token raises the limit." }
            else { "\(host) is limiting requests. Try again later. Adding an access token raises the limit." }
        case .badResponse(let why): "The service sent an answer that could not be used (\(why))."
        case .tooLarge: "That listing is larger than this feature will read."
        case .expiredLink: "That link has expired. Get a fresh one from the service; an expired link is not retried."
        case .network(let why): "The service could not be reached (\(why))."
        case .notEnoughSpace(let needed, let available):
            "There is not enough free space: \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed, \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free."
        }
    }
    static func wait(_ s: TimeInterval) -> String { let s = s.isFinite ? min(max(s, 0), 86_400) : 86_400; return s < 90 ? "\(Int(s.rounded(.up))) seconds" : "\(Int((s / 60).rounded(.up))) minutes" }
}

/// One GET, no redirects handled by the caller. A seam so tests can serve answers from a local server.
struct ProviderResponse: Sendable {
    var status: Int
    var headers: [String: String]       // lower-cased names
    var body: Data
    var finalURL: URL
}

protocol ProviderTransport: Sendable {
    func get(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> ProviderResponse
}

/// The real transport. Rules (the same as downloads):
///  - the Authorization header is chosen by the account router for the EXACT host, over https only, never for a private tab, and is never part of a URL;
///  - on a redirect to another origin (scheme, host, port) the header is dropped; https → http is refused; at most 5 redirects;
///  - the body is read up to a limit.
final class URLSessionProviderTransport: NSObject, ProviderTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let authorization: @Sendable (URL) -> String?
    private let policyCheck: @Sendable (URL) throws -> Void
    private let session: URLSession

    init(authorization: @escaping @Sendable (URL) -> String?, policyCheck: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.authorization = authorization; self.policyCheck = policyCheck
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil; c.timeoutIntervalForRequest = 30
        session = URLSession(configuration: c, delegate: nil, delegateQueue: nil)
        super.init()
    }

    func get(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> ProviderResponse {
        try policyCheck(url)
        var request = URLRequest(url: url)
        for (k, v) in headers where k.lowercased() != "authorization" { request.setValue(v, forHTTPHeaderField: k) }
        if let auth = authorization(url) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let box = Collector(maxBytes: maxBytes)
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProviderResponse, Error>) in
                task.delegate = Delegate(box: box, owner: self, continuation: cont, original: url)
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    final class Collector: @unchecked Sendable { var data = Data(); let maxBytes: Int; init(maxBytes: Int) { self.maxBytes = maxBytes } }

    /// Holds one request's state.
    final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let box: Collector; let owner: URLSessionProviderTransport; var cont: CheckedContinuation<ProviderResponse, Error>?
        var redirects = 0; var response: HTTPURLResponse?; var overflow = false; let original: URL
        init(box: Collector, owner: URLSessionProviderTransport, continuation: CheckedContinuation<ProviderResponse, Error>, original: URL) { self.box = box; self.owner = owner; cont = continuation; self.original = original; chain = [original] }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            guard let from = task.currentRequest?.url ?? Optional(original), let to = request.url, redirects <= 5, let outcome = Self.redirect(from: from, to: to, request: request, check: owner.policyCheck) else { completionHandler(nil); return }
            let history = chain
            chain.append(to)
            Task { completionHandler(await Self.resolvesSafely(from: from, to: to, chain: history) ? outcome : nil) }
        }
        var chain: [URL] = []
        /// What the target name really leads to: the shared network rules (the same ones the download engines apply). A public name that resolves into this computer or the local network is
        /// refused; a request that began at a local address (a typed, self-hosted service) may still go on to its own network. Authentication is not touched here.
        static func resolvesSafely(from: URL, to: URL, chain: [URL], resolve: (String) async -> (kind: HostClass, resolved: [String]?) = { await HTTPRequestPolicy.classifyResolving(host: $0) }) async -> Bool {
            if case .follow = await HTTPRequestPolicy(origin: .user).decideRedirectResolving(from: from, to: to, chain: chain.isEmpty ? [from] : chain, resolve: resolve) { return true }
            return false
        }
        /// nil = refuse. Same origin keeps the request; another origin loses the credential (and anything else that identifies the person).
        static func redirect(from: URL, to: URL, request: URLRequest, check: (URL) throws -> Void) -> URLRequest? {
            guard to.scheme == "https" || (to.scheme == "http" && from.scheme == "http") else { return nil }
            guard (try? check(to)) != nil else { return nil }
            // A public address must not send the request on to this computer or the local network (a typed local address may still go to its own network).
            if (try? HTTPRequestPolicy(origin: .page).check(from)) != nil, (try? HTTPRequestPolicy(origin: .page).check(to)) == nil { return nil }
            var r = request
            if ProviderOrigin(from) != ProviderOrigin(to) { r.setValue(nil, forHTTPHeaderField: "Authorization"); r.setValue(nil, forHTTPHeaderField: "Cookie") }
            return r
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse; completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if box.data.count + data.count > box.maxBytes { overflow = true; dataTask.cancel(); return }
            box.data.append(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let c = cont else { return }; cont = nil
            if overflow { c.resume(throwing: ProviderError.tooLarge); return }
            if let error { c.resume(throwing: (error as? ProviderError) ?? ProviderError.network((error as NSError).code == NSURLErrorCancelled ? "cancelled" : error.localizedDescription)); return }
            guard let r = response else { c.resume(throwing: ProviderError.badResponse("no answer")); return }
            var h: [String: String] = [:]
            for (k, v) in r.allHeaderFields { if let k = k as? String, let v = v as? String { h[k.lowercased()] = v } }
            c.resume(returning: ProviderResponse(status: r.statusCode, headers: h, body: box.data, finalURL: r.url ?? original))
        }
    }
}

struct ProviderOrigin: Equatable {
    let scheme: String, host: String, port: Int
    init(_ u: URL) { scheme = u.scheme?.lowercased() ?? ""; host = u.host?.lowercased() ?? ""; port = u.port ?? (scheme == "https" ? 443 : 80) }
}

/// Reads a service's rate-limit and error answers the same way for every provider.
enum ProviderStatus {
    static func check(_ r: ProviderResponse, host: String, hadToken: Bool) throws {
        switch r.status {
        case 200..<300, 304: return
        case 401: throw ProviderError.unauthorized(host: host, hadToken: hadToken)
        case 404: throw ProviderError.notFound
        case 403, 429:
            if let after = r.headers["retry-after"].flatMap(TimeInterval.init), after.isFinite { throw ProviderError.rateLimited(retryAfter: after, host: host) }
            if r.headers["x-ratelimit-remaining"] == "0" {
                let reset = r.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).flatMap { $0.isFinite ? max(0, $0 - Date().timeIntervalSince1970) : nil }
                throw ProviderError.rateLimited(retryAfter: reset, host: host)
            }
            if r.status == 429 { throw ProviderError.rateLimited(retryAfter: nil, host: host) }
            let text = String(decoding: r.body.prefix(400), as: UTF8.self)
            if text.lowercased().contains("gated") || r.headers["x-error-code"]?.lowercased() == "gatedrepo" { throw ProviderError.gated }
            throw hadToken ? ProviderError.forbidden("the saved token may not have permission for this") : ProviderError.unauthorized(host: host, hadToken: false)
        default: throw ProviderError.badResponse("status \(r.status)")
        }
    }
}

enum ProviderNames {
    /// A size from a service: never negative, never absurd (so sums cannot overflow).
    static func size(_ n: Int64?) -> Int64? { n.map { min(max($0, 0), 1 << 50) } }
    static func sum(_ files: [ProviderFile]) -> Int64 { files.reduce(Int64(0)) { $0 + ($1.size ?? 0) } }          // (each size is clamped at 2^50, so thousands of them cannot overflow)

    /// A file name that is only a name: no folders, no leading dots, never empty.
    static func safe(_ s: String) -> String { DownloadFilename.sanitize(s) ?? "download" }
}
