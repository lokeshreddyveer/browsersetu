import Foundation
import CryptoKit

/// Webhooks: optional, off by default, and only to a destination the person typed in. Nothing here weakens the download request policy; it is a separate, narrower thing
/// (a notification the app sends, with no file fetched and no reply used).
struct WebhookEndpoint: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var url: URL
    var createdAt: Date
    var enabled = true
    /// Event types wanted; empty means all.
    var events: [String] = []
}

enum WebhookDestination {
    enum Refusal: Error, Equatable { case notWeb, credentials, query, onlyThisMac(String) }

    /// Webhooks go to this Mac's own address and nowhere else, written as a number: `127.0.0.1` or `[::1]`.
    ///
    /// Why not a website: to be sure a request goes where it was checked, the connection itself would have to be made to the address that was checked. The system's URL loading looks a
    /// name up again when it connects, so a name that answered "public" a moment ago could answer "your router" now (DNS rebinding), and there is no supported way to pin the address and
    /// still verify a certificate for the name. So a name, a private-network address and any other number are refused rather than half-checked. No lookup is ever made here.
    static func validate(_ url: URL, resolver: ((String) -> [String]?)? = nil) -> Refusal? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return .notWeb }
        guard url.user == nil, url.password == nil else { return .credentials }
        guard url.query == nil, url.fragment == nil else { return .query }
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let isV4Loopback: Bool = { let p = literal.split(separator: ".", omittingEmptySubsequences: false); return p.count == 4 && p[0] == "127" && p.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 } }()
        let isV6Loopback = literal == "::1"
        guard isV4Loopback || isV6Loopback else { return .onlyThisMac(host) }
        return nil
    }
}

enum WebhookSigner {
    /// `t=<unix>,v1=<hex HMAC-SHA256 of "<t>.<body>">` — the same scheme webhook receivers already know, with a timestamp so a captured request cannot be replayed later.
    static func header(secret: Data, body: Data, at time: Date) -> String {
        let t = Int(time.timeIntervalSince1970)
        var message = Data("\(t).".utf8); message.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return "t=\(t),v1=\(Data(mac).map { String(format: "%02x", $0) }.joined())"
    }

    static func verify(header: String, secret: Data, body: Data, now: Date, tolerance: TimeInterval = 300) -> Bool {
        var t: Int?, sig: String?
        for part in header.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { if kv[0] == "t" { t = Int(kv[1]) } else if kv[0] == "v1" { sig = kv[1] } }
        }
        guard let t, let sig, abs(now.timeIntervalSince1970 - Double(t)) <= tolerance else { return false }
        return AgentHTTP.constantTimeEqual(Self.header(secret: secret, body: body, at: Date(timeIntervalSince1970: Double(t))), "t=\(t),v1=\(sig)")
    }
}

/// How a webhook is actually sent. Replaceable so tests need no network.
protocol WebhookTransport: Sendable {
    /// The HTTP status, or nil if nothing was received. Redirects must not be followed.
    func post(_ url: URL, headers: [String: String], body: Data) async -> Int?
}

struct URLSessionWebhookTransport: WebhookTransport {
    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }
    func post(_ url: URL, headers: [String: String], body: Data) async -> Int? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.connectionProxyDictionary = [:]; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return (try? await session.data(for: request).1 as? HTTPURLResponse)?.statusCode
    }
}

/// Delivers events to approved endpoints: a bounded queue, a few attempts with growing waits, and no reply ever used.
@MainActor
final class AutomationWebhooks: ObservableObject {
    static let maxEndpoints = 5
    static let maxQueue = 100
    static let maxAttempts = 3

    @Published private(set) var endpoints: [WebhookEndpoint] = []
    @Published private(set) var delivered = 0
    @Published private(set) var dropped = 0
    private var queue: [(endpoint: WebhookEndpoint, body: Data)] = []
    private var draining = false
    private let transport: WebhookTransport
    private let secrets: AutomationSecretVault
    private let sleeper: (TimeInterval) async -> Void
    private let clock: () -> Date
    private let file: URL?

    init(file: URL?, secrets: AutomationSecretVault, transport: WebhookTransport = URLSessionWebhookTransport(), sleeper: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }, clock: @escaping () -> Date = Date.init) {
        self.file = file; self.secrets = secrets; self.transport = transport; self.sleeper = sleeper; self.clock = clock
        if let file, let data = try? Data(contentsOf: file), let list = try? AutomationJSON.decoder.decode([WebhookEndpoint].self, from: data) { endpoints = list }
    }

    enum AddResult: Equatable { case added(WebhookEndpoint, secret: String); case refused(String) }

    func add(_ url: URL, events: [String] = []) -> AddResult {
        guard endpoints.count < Self.maxEndpoints else { return .refused("Too many webhooks.") }
        if let why = WebhookDestination.validate(url) { return .refused(Self.explain(why)) }
        let endpoint = WebhookEndpoint(id: String(AgentHTTP.makeToken().prefix(8)), url: url, createdAt: clock(), events: events)
        let secret = AgentHTTP.makeToken()
        guard secrets.store(Data(secret.utf8), for: endpoint.id) else { return .refused("The signing secret could not be stored safely.") }
        endpoints.append(endpoint)
        save()
        return .added(endpoint, secret: secret)
    }

    func remove(_ id: String) { endpoints.removeAll { $0.id == id }; secrets.remove(endpoint: id); save() }
    func setEnabled(_ id: String, _ on: Bool) { if let i = endpoints.firstIndex(where: { $0.id == id }) { endpoints[i].enabled = on; save() } }

    static func explain(_ r: WebhookDestination.Refusal) -> String {
        switch r {
        case .notWeb: "Use an http or https address."
        case .credentials: "Do not put a user name or password in the address."
        case .query: "Leave out anything after a “?” or “#”."
        case .onlyThisMac(let h): "Webhooks can only go to this Mac (127.0.0.1). “\(h)” is a name or another address, and there is no safe way to make sure a request goes only where it was checked."
        }
    }

    /// The only data a webhook carries: no address, no file name, no path, no credential.
    static func payload(for event: AutomationEvent) -> Data {
        struct Body: Encodable { var id: Int; var type: String; var task: String?; var state: String?; var fraction: Double?; var bytes: Int64?; var host: String?; var at: Date }
        return (try? AutomationJSON.encoder.encode(Body(id: event.id, type: event.type, task: event.taskID, state: event.state, fraction: event.fraction, bytes: event.bytesReceived, host: event.sourceHost, at: event.at))) ?? Data()
    }

    func enqueue(_ event: AutomationEvent) {
        guard event.type != "task.progress" else { return }      // webhooks are for things that happened, not for every percent
        let body = Self.payload(for: event)
        for endpoint in endpoints where endpoint.enabled && (endpoint.events.isEmpty || endpoint.events.contains(event.type)) {
            if queue.count >= Self.maxQueue { queue.removeFirst(); dropped += 1 }
            queue.append((endpoint, body))
        }
        drain()
    }

    private func drain() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { @MainActor in
            while !queue.isEmpty {
                let item = queue.removeFirst()
                await deliver(item.endpoint, item.body)
            }
            draining = false
        }
    }

    private func deliver(_ endpoint: WebhookEndpoint, _ body: Data) async {
        for attempt in 1...Self.maxAttempts {
            // Checked again at delivery, because a name can move: an address that is private now is never sent to.
            let allowed = WebhookDestination.validate(endpoint.url) == nil          // a number check only: no lookup, nothing to wait for
            guard allowed, endpoints.contains(where: { $0.id == endpoint.id && $0.enabled }),
                  let secret = secrets.secret(for: endpoint.id) else { dropped += 1; return }
            let headers = ["Content-Type": "application/json", "User-Agent": "BrowserSetu-Webhook/1", "X-BrowserSetu-Signature": WebhookSigner.header(secret: secret, body: body, at: clock())]
            if let status = await transport.post(endpoint.url, headers: headers, body: body), (200..<300).contains(status) { delivered += 1; return }
            if attempt < Self.maxAttempts { await sleeper(Double(attempt * attempt) * 2) }
        }
        dropped += 1
    }

    var pendingCount: Int { queue.count }

    /// Waits until everything queued has been tried (for tests).
    func flush() async { while draining || !queue.isEmpty { try? await Task.sleep(for: .milliseconds(5)) } }

    private func save() {
        guard let file, let data = try? AutomationJSON.encoder.encode(endpoints) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
    }
}

/// Where webhook signing secrets live. The real one is the macOS Keychain; tests use memory and never touch the real Keychain.
protocol AutomationSecretVault {
    func store(_ secret: Data, for endpoint: String) -> Bool
    func secret(for endpoint: String) -> Data?
    func remove(endpoint: String)
}

final class MemorySecretVault: AutomationSecretVault {
    private var items: [String: Data] = [:]
    func store(_ secret: Data, for endpoint: String) -> Bool { items[endpoint] = secret; return true }
    func secret(for endpoint: String) -> Data? { items[endpoint] }
    func remove(endpoint: String) { items[endpoint] = nil }
}

struct KeychainSecretVault: AutomationSecretVault {
    var profile: String
    private var service: String { "com.browsersetu.automation.webhook." + profile }
    init(profile: String) { self.profile = profile }
    func store(_ secret: Data, for endpoint: String) -> Bool { SecretStore.set(secret, service: service, account: endpoint) }
    func secret(for endpoint: String) -> Data? { SecretStore.get(service: service, account: endpoint) }
    func remove(endpoint: String) { _ = SecretStore.delete(service: service, account: endpoint) }
}
