import Foundation
import Network

/// How the app's own downloader reaches the network. These settings are about the standalone downloader only; the browser's pages use WebKit's own networking and the system's proxy settings,
/// and nothing here changes either (nor the Mac's network settings).
///
/// Saved per profile as one small JSON value, with no secret in it: a proxy's password lives in the Keychain (`ProxyCredentialStore`).
struct DownloadNetworkSettings: Codable, Equatable, Sendable {
    // MARK: Speed
    /// Bytes per second for all downloads together; nil is unlimited.
    var overallLimit: Int64?

    // MARK: Connections
    /// Most connections to one website at once, across all downloads.
    var perHostConnections = ConnectionBudget.perHostLimit
    /// Most connections one download uses when it is fetched in pieces.
    var workersPerDownload = MultipartPlanner.defaultConnections
    /// Seconds to wait for a website to answer, and for data to keep arriving.
    var requestTimeout = DownloadNetworkSettings.defaultTimeout
    /// How many times a failed download is tried again by itself.
    var maxAutomaticRetries = DownloadNetworkSettings.defaultRetries

    // MARK: Adaptive behaviour
    /// How the downloader reacts to measured conditions. `unlimited` and `custom` add nothing of their own: the numbers above are all that applies.
    var adaptiveMode = AdaptiveMode.unlimited
    /// Seconds a page load or video keeps the browser "busy" after it ends, so downloads do not speed up and slow down with every click.
    var browserGraceSeconds = DownloadNetworkSettings.defaultGrace

    // MARK: Network conditions
    var pauseOnExpensive = false
    var respectLowDataMode = false
    var waitForConnectivity = false

    // MARK: Proxy
    var proxy = Proxy()

    struct Proxy: Codable, Equatable, Sendable {
        enum Mode: String, Codable, CaseIterable, Sendable { case system, direct, http, https, socks5 }
        var mode: Mode = .system
        var host = ""
        var port = 0
        var username = ""
    }

    // MARK: Limits that are accepted
    /// Fixed numbers, not read from the engines: those can be changed by these very settings.
    static let defaultTimeout = 30
    static let defaultRetries = 3
    static let connectionRange = 1...8
    static let timeoutRange = 10...120
    static let retryRange = 0...10
    static let defaultGrace = 8
    static let graceRange = 2...60
    static let maximumLimit: Int64 = 10 * 1024 * 1024 * 1024         // 10 GiB/s: anything above is the same as none

    /// The settings with every value brought into its allowed range (a hand-edited or old value can never reach the engines unchecked).
    func normalized() -> DownloadNetworkSettings {
        var s = self
        if let limit = s.overallLimit { s.overallLimit = BandwidthController.valid(limit).map { min($0, Self.maximumLimit) } }
        s.perHostConnections = min(max(s.perHostConnections, Self.connectionRange.lowerBound), Self.connectionRange.upperBound)
        s.workersPerDownload = min(max(s.workersPerDownload, Self.connectionRange.lowerBound), Self.connectionRange.upperBound)
        s.browserGraceSeconds = min(max(s.browserGraceSeconds, Self.graceRange.lowerBound), Self.graceRange.upperBound)
        s.requestTimeout = min(max(s.requestTimeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        s.maxAutomaticRetries = min(max(s.maxAutomaticRetries, Self.retryRange.lowerBound), Self.retryRange.upperBound)
        s.proxy.host = s.proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        s.proxy.username = String(s.proxy.username.prefix(255))
        return s
    }

    /// The speed, connection, wait, retry and adaptive choices back at their defaults. The proxy and the network choices (metered, Low Data Mode, offline) are the person's rules and stay.
    func resettingSpeedAndConnections() -> DownloadNetworkSettings {
        var fresh = DownloadNetworkSettings()
        fresh.proxy = proxy; fresh.pauseOnExpensive = pauseOnExpensive; fresh.respectLowDataMode = respectLowDataMode; fresh.waitForConnectivity = waitForConnectivity
        return fresh
    }

    // MARK: Saving

    func encoded() -> String? { (try? JSONEncoder().encode(normalized())).flatMap { String(data: $0, encoding: .utf8) } }

    /// Settings from their saved text. Anything unreadable gives the defaults (which behave as before this feature existed); missing fields keep their defaults.
    static func decode(_ text: String?) -> DownloadNetworkSettings {
        guard let text, let data = text.data(using: .utf8), text.utf8.count < 16_384, let decoded = try? JSONDecoder().decode(DownloadNetworkSettings.self, from: data) else { return DownloadNetworkSettings() }
        return decoded.normalized()
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        overallLimit = try c.decodeIfPresent(Int64.self, forKey: .overallLimit)
        perHostConnections = try c.decodeIfPresent(Int.self, forKey: .perHostConnections) ?? perHostConnections
        workersPerDownload = try c.decodeIfPresent(Int.self, forKey: .workersPerDownload) ?? workersPerDownload
        requestTimeout = try c.decodeIfPresent(Int.self, forKey: .requestTimeout) ?? requestTimeout
        maxAutomaticRetries = try c.decodeIfPresent(Int.self, forKey: .maxAutomaticRetries) ?? maxAutomaticRetries
        adaptiveMode = (try c.decodeIfPresent(String.self, forKey: .adaptiveMode)).flatMap(AdaptiveMode.init(rawValue:)) ?? .unlimited
        browserGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .browserGraceSeconds) ?? Self.defaultGrace
        pauseOnExpensive = try c.decodeIfPresent(Bool.self, forKey: .pauseOnExpensive) ?? false
        respectLowDataMode = try c.decodeIfPresent(Bool.self, forKey: .respectLowDataMode) ?? false
        waitForConnectivity = try c.decodeIfPresent(Bool.self, forKey: .waitForConnectivity) ?? false
        proxy = try c.decodeIfPresent(Proxy.self, forKey: .proxy) ?? Proxy()
    }

    private enum Keys: String, CodingKey {
        case overallLimit, perHostConnections, workersPerDownload, requestTimeout, maxAutomaticRetries, adaptiveMode, browserGraceSeconds, pauseOnExpensive, respectLowDataMode, waitForConnectivity, proxy
    }

    // MARK: Presets

    /// A preset changes only the numbers below. It never touches the proxy, the network conditions or anything about privacy.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case unlimited, balanced, limited, custom
        var id: String { rawValue }
        var title: String {
            switch self { case .unlimited: "Unlimited"; case .balanced: "Balanced"; case .limited: "Limited bandwidth"; case .custom: "Custom" }
        }
        var detail: String {
            switch self {
            case .unlimited: "No speed limit; up to 4 connections per file."
            case .balanced: "Up to 8 MB/s for downloads that can be slowed, up to 4 connections per file, 4 per website."
            case .limited: "Up to 1 MB/s for downloads that can be slowed, 2 connections per file, 2 per website."
            case .custom: "Your own numbers."
            }
        }
    }

    /// What a preset sets: speed and connection counts, nothing else.
    func applying(_ preset: Preset) -> DownloadNetworkSettings {
        var s = self
        switch preset {
        case .unlimited: s.overallLimit = nil; s.workersPerDownload = MultipartPlanner.defaultConnections; s.perHostConnections = ConnectionBudget.perHostLimit
        case .balanced: s.overallLimit = 8 * 1024 * 1024; s.workersPerDownload = 4; s.perHostConnections = 4
        case .limited: s.overallLimit = 1024 * 1024; s.workersPerDownload = 2; s.perHostConnections = 2
        case .custom: break
        }
        return s.normalized()
    }

    /// Which preset these numbers are exactly; custom when none.
    var preset: Preset {
        for p in [Preset.unlimited, .balanced, .limited] {
            let r = applying(p)
            if r.overallLimit == overallLimit, r.workersPerDownload == workersPerDownload, r.perHostConnections == perHostConnections { return p }
        }
        return .custom
    }
}

// MARK: Proxy

/// Turns the proxy choice into a session configuration, or says plainly why it cannot.
///
/// Verified against Apple's documentation (macOS 14 and later): `URLSessionConfiguration.proxyConfigurations` takes `Network.ProxyConfiguration` values, built for HTTP CONNECT (over a plain or a
/// TLS connection to the proxy) and for SOCKS version 5, with optional user name and password. `allowFailover` is left off, so a proxy that is down is an error and never a quiet direct connection.
/// Proxy auto-configuration scripts and relay/oblivious proxies are not offered. "System" leaves the session on the Mac's own proxy settings; "Direct" turns every proxy off for the downloader.
enum DownloadProxy {
    enum Problem: Error, Equatable, LocalizedError {
        case missingHost, badHost, badPort, notForUntrustedRequests, missingPassword
        var errorDescription: String? {
            switch self {
            case .missingHost: "Enter the proxy's address."
            case .badHost: "The proxy's address must be a host name or IP address, with no “http://”, path or spaces."
            case .badPort: "The proxy's port must be a number from 1 to 65535."
            case .missingPassword: "The proxy needs a password and none is saved for this profile. Enter it in the proxy settings."
            case .notForUntrustedRequests: "Downloads that are not the person's own are never sent through a proxy, because where they really connect could not be checked."
            }
        }
    }

    /// Nil when the settings can be used.
    static func problem(_ proxy: DownloadNetworkSettings.Proxy) -> Problem? {
        switch proxy.mode {
        case .system, .direct: return nil
        case .http, .https, .socks5:
            let host = proxy.host.trimmingCharacters(in: .whitespaces)
            if host.isEmpty { return .missingHost }
            if host.count > 253 || host.contains(where: { $0.isWhitespace || "/@?#\\:[]%".contains($0) || !$0.isASCII }) {
                // A bracketed or plain IPv6 literal is allowed; everything else with these characters is not.
                if !(IPv6Address(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) != nil) { return .badHost }
            }
            if !(1...65535).contains(proxy.port) { return .badPort }
            return nil
        }
    }

    /// A short statement of what this choice does, for the settings and the status line.
    static func summary(_ proxy: DownloadNetworkSettings.Proxy) -> String {
        switch proxy.mode {
        case .system: "Uses your Mac's proxy settings."
        case .direct: "No proxy: connects directly, ignoring your Mac's proxy settings."
        case .http: "HTTP proxy at \(proxy.host):\(proxy.port) (tunnels with CONNECT)."
        case .https: "HTTPS proxy at \(proxy.host):\(proxy.port) (encrypted link to the proxy)."
        case .socks5: "SOCKS5 proxy at \(proxy.host):\(proxy.port)."
        }
    }

    /// What each choice supports, stated once and used by the settings text and the tests.
    static func capabilities(_ mode: DownloadNetworkSettings.Proxy.Mode) -> (httpTargets: Bool, httpsTargets: Bool, authentication: Bool, encryptedToProxy: Bool) {
        switch mode {
        case .system, .direct: return (true, true, false, false)
        case .http: return (true, true, true, false)
        case .https: return (true, true, true, true)
        case .socks5: return (true, true, true, false)
        }
    }

    /// The `ProxyConfiguration` for an explicit choice, or nil for system and direct.
    static func configuration(for proxy: DownloadNetworkSettings.Proxy, password: String?) -> ProxyConfiguration? {
        guard proxy.mode == .http || proxy.mode == .https || proxy.mode == .socks5, let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) else { return nil }
        let host = NWEndpoint.Host(proxy.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        var configuration: ProxyConfiguration
        switch proxy.mode {
        case .socks5: configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http: configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        default: configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        configuration.allowFailover = false                   // a proxy that fails is an error, never a quiet direct connection
        if !proxy.username.isEmpty, let password, !password.isEmpty { configuration.applyCredential(username: proxy.username, password: password) }
        return configuration
    }

    /// Applies the choice to a session configuration. Throws, changing nothing, when the choice is unusable or the request is not the person's own.
    static func apply(_ proxy: DownloadNetworkSettings.Proxy, password: String?, origin: DownloadRequestOrigin, to config: URLSessionConfiguration) throws {
        if let problem = problem(proxy) { throw problem }
        switch proxy.mode {
        case .system:
            return
        case .direct:
            // An explicit "no proxy" for every kind of proxy the system can name.
            config.connectionProxyDictionary = [
                "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "FTPEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,     // the keys CFNetwork documents (named constants are macOS-only)
            ]
        case .http, .https, .socks5:
            // With a proxy, the address the connection really goes to cannot be seen, so nothing that is not the person's own request may use one.
            guard origin == .user else { throw Problem.notForUntrustedRequests }
            // A user name means the proxy wants a login. Without the password it would be asked with no credential and the connection simply waits; it is an error, said at once.
            if !proxy.username.isEmpty, (password ?? "").isEmpty { throw Problem.missingPassword }
            guard let configuration = configuration(for: proxy, password: password) else { throw Problem.badPort }
            config.proxyConfigurations = [configuration]
        }
    }
}

/// Where a proxy's password is kept. The Keychain in the app; memory in tests. The password is never part of the saved settings, a task record, a row, or a diagnostic.
protocol ProxyCredentialStore: Sendable {
    func password(profile: String) -> String?
    func setPassword(_ password: String?, profile: String)
}

struct KeychainProxyCredentialStore: ProxyCredentialStore {
    private static func service(_ profile: String) -> String { "com.browsersetu.downloadproxy." + profile }
    private static let account = "password"

    func password(profile: String) -> String? {
        SecretStore.get(service: Self.service(profile), account: Self.account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setPassword(_ password: String?, profile: String) {
        if let password, !password.isEmpty { _ = SecretStore.set(Data(password.utf8), service: Self.service(profile), account: Self.account) }
        else { _ = SecretStore.delete(service: Self.service(profile), account: Self.account) }
    }
}

final class MemoryProxyCredentialStore: ProxyCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func password(profile: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[profile] }
    func setPassword(_ password: String?, profile: String) { lock.lock(); values[profile] = (password?.isEmpty == false) ? password : nil; lock.unlock() }
}

// MARK: Network conditions

/// Why new and running downloads are being held by the network policy (as opposed to the person having paused them).
enum NetworkHold: String, Equatable, Sendable {
    case offline, expensive, constrained

    var explanation: String {
        switch self {
        case .offline: "Waiting for a network connection."
        case .expensive: "Paused on a metered connection (your setting)."
        case .constrained: "Paused while Low Data Mode is on (your setting)."
        }
    }
}

/// Decides, from what the system reports and the person's settings, whether downloads should wait. Pure, so every combination can be tested.
enum NetworkPolicy {
    static func hold(for path: PathInfo, settings: DownloadNetworkSettings) -> NetworkHold? {
        if !path.online { return settings.waitForConnectivity ? .offline : nil }
        if path.constrained, settings.respectLowDataMode { return .constrained }
        if path.expensive, settings.pauseOnExpensive { return .expensive }
        return nil
    }
}

// MARK: What the engines are given

/// The network settings as the transfer engines use them: no saved fields, and the proxy password in memory only. Never logged, never put in a record.
struct DownloadNetworkSetup: Sendable, Equatable {
    var proxy = DownloadNetworkSettings.Proxy()
    var proxyPassword: String?
    var requestTimeout = TimeInterval(DownloadNetworkSettings.defaultTimeout)
    var perHostConnections = ConnectionBudget.perHostLimit
    var workers = MultipartPlanner.defaultConnections
    var refuseExpensive = false
    var refuseConstrained = false
    /// How many tries a failing transfer gets (the first included): this profile's own number, never a process-wide one.
    var maxAttempts = 4

    init() {}

    init(_ settings: DownloadNetworkSettings, password: String?) {
        proxy = settings.proxy; proxyPassword = password
        requestTimeout = TimeInterval(settings.requestTimeout)
        perHostConnections = settings.perHostConnections; workers = settings.workersPerDownload
        refuseExpensive = settings.pauseOnExpensive; refuseConstrained = settings.respectLowDataMode
        maxAttempts = settings.maxAutomaticRetries + 1
    }

    /// A failure to use the proxy, in the shape a transfer reports: stated plainly, not retried by itself (retrying cannot fix a setting).
    static func failure(for error: Error) -> HTTPDownloadError {
        let reason = (error as? LocalizedError)?.errorDescription ?? "The proxy settings could not be used."
        return HTTPDownloadError(info: DownloadFailureInfo(code: "proxy:unusable", reason: reason, retryable: false))
    }
}
