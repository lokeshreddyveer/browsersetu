import Foundation

// What an HTTP download may ask for, and where it may be sent. This is shared by the single-transfer engine and, in Phase 3, the multipart engine: one place decides which
// addresses are reachable, which headers go out, and which redirects are followed, so a second engine cannot be more permissive than the first.

/// Who asked for the download. A person typing or pasting an address is trusted to reach their own network (a NAS, a local server); a script, an extension or an API caller is not.
enum DownloadRequestOrigin: String, Codable, Sendable {
    case user
    case automation
    case browserExtension
    /// An address the person approved but that came from a web page, the clipboard or a crawl rather than from their own typing. Their approval starts the download; it does not
    /// give the address the reach of one they typed: it is held to the untrusted network rules (no local network, checked DNS and connection, no proxy it cannot see through).
    case page
}

enum HostClass: Equatable, Sendable {
    case publicHost, loopback, privateNetwork, linkLocal, unspecified, localName

    /// Not reachable from the open internet.
    var isInternal: Bool { self != .publicHost }
}

struct HTTPRequestPolicy: Sendable {
    static let maxRedirects = 10
    /// Seconds a website may take to answer or go quiet; the person can change it (10 to 120) in the network settings.
    nonisolated(unsafe) static var defaultRequestTimeout: TimeInterval = 30
    static let defaultResourceTimeout: TimeInterval = 60 * 60 * 24

    var origin: DownloadRequestOrigin
    var maxRedirects = HTTPRequestPolicy.maxRedirects
    var requestTimeout = HTTPRequestPolicy.defaultRequestTimeout
    var resourceTimeout = HTTPRequestPolicy.defaultResourceTimeout
    var userAgent: String?

    /// Only the person's own requests may reach private, loopback and link-local addresses.
    var allowsInternalHosts: Bool { origin == .user || Self.debugFixtureAllowsLocalPageOrigin }

    /// Test seam, compiled into Debug builds only and off unless the app is launched with `-UITestAllowLocalPageOrigin YES`: lets a page-origin request reach the loopback fixture server so a real
    /// page-to-file download can be exercised. Release builds have the constant `false`, so the rule above is the whole rule there. Tests assert the default stays closed.
    /// True when a request that came from a page may go to this host: any public host. (Local and private names are refused; the Debug-only fixture seam above is the sole exception.)
    static func pageMayReach(host: String) -> Bool { !classify(host: host).isInternal || debugFixtureAllowsLocalPageOrigin }

    static var debugFixtureAllowsLocalPageOrigin: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "UITestAllowLocalPageOrigin")
        #else
        return false
        #endif
    }

    init(origin: DownloadRequestOrigin = .user, userAgent: String? = nil) { self.origin = origin; self.userAgent = userAgent }

    // MARK: Headers

    /// Headers a caller may set. Anything else (Cookie, Host, Range, Content-Length…) is the engine's business and is refused.
    static let approvedHeaders: Set<String> = ["accept", "accept-language", "referer", "user-agent", "origin"]
    /// Sent only to the origin they were given for, and only for the person's own requests; never saved to disk.
    static let credentialHeaders: Set<String> = ["authorization"]

    /// What survives: approved headers, plus credentials when the person supplied them. `dropped` names what was refused (names only, never values).
    func sanitize(_ headers: [String: String]) -> (kept: [String: String], dropped: [String]) {
        var kept: [String: String] = [:], dropped: [String] = []
        for (name, value) in headers {
            let key = name.lowercased()
            let clean = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } && value.utf8.count <= 4096
            if !clean { dropped.append(name); continue }
            if Self.approvedHeaders.contains(key) { kept[name] = value }
            else if Self.credentialHeaders.contains(key), origin == .user { kept[name] = value }
            else { dropped.append(name) }
        }
        return (kept, dropped)
    }

    // MARK: Addresses

    enum Refusal: Error, Equatable, Sendable {
        case unsupportedScheme(String)
        case missingHost
        case internalAddress(String)
        case tooManyRedirects
        case redirectLoop
        case insecureRedirect
        case redirectIntoInternalNetwork(String)
        /// The name could not be resolved here, so where it leads cannot be checked, and this kind of request is only for places that can be.
        case unverifiable(String)
        /// The connection that was actually made went to an internal address (a name that resolved differently the second time).
        case connectedToInternalAddress(String, String)
        /// Requests from scripts and extensions are not accepted yet: nothing can stop a connection to a private address before it is made, only notice it afterwards.
        case untrustedRequestsDisabled

        var reason: String {
            switch self {
            case .unsupportedScheme(let s): "Only http and https addresses can be downloaded (this one is \(s.isEmpty ? "missing a scheme" : s))."
            case .missingHost: "The address has no website name."
            case .internalAddress(let h): "\(h) is on a private network, which this kind of download is not allowed to reach."
            case .tooManyRedirects: "The address redirected too many times."
            case .redirectLoop: "The address redirects back to itself."
            case .insecureRedirect: "A secure address tried to send the download to an insecure one, so it was stopped."
            case .redirectIntoInternalNetwork(let h): "The address redirected to \(h), a private network address, so it was stopped."
            case .unverifiable(let h): "Where \(h) leads could not be checked, and this kind of download only goes to places that can be."
            case .connectedToInternalAddress(let h, _): "\(h) connected to a private network address, so the download was stopped and discarded."
            case .untrustedRequestsDisabled: "Downloads asked for by a script or an extension are not allowed yet."
            }
        }
    }

    /// Whether requests that are not the person's own may be made at all. Off: the system's networking offers no way to refuse a connection before it is made, so a name that
    /// leads to a private address could be reached (and only noticed afterwards). The later checks (resolving first, checking redirects and the real connection) stay as layers
    /// behind this one, for when it is turned on; they are not a reason to turn it on. Tests that exercise those layers switch it on and restore it.
    nonisolated(unsafe) static var untrustedRequestsEnabled = false

    /// Fails closed: a request that is not the person's own is refused before anything is resolved or sent.
    func requireAllowedOrigin() throws {
        if origin != .user, origin != .page, !Self.untrustedRequestsEnabled { throw Refusal.untrustedRequestsDisabled }
    }

    /// Whether a first address may be fetched at all.
    func check(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw Refusal.unsupportedScheme(scheme) }
        guard let host = url.host, !host.isEmpty else { throw Refusal.missingHost }
        if Self.classify(host: host).isInternal, !allowsInternalHosts { throw Refusal.internalAddress(host) }
    }

    enum RedirectDecision: Equatable, Sendable {
        case follow(dropCredentials: Bool)
        case refuse(Refusal)
    }

    /// `chain` is every address visited so far, in order, ending with `from`.
    func decideRedirect(from: URL, to: URL, chain: [URL]) -> RedirectDecision {
        let scheme = to.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .refuse(.unsupportedScheme(scheme)) }
        guard let host = to.host, !host.isEmpty else { return .refuse(.missingHost) }
        if chain.count > maxRedirects { return .refuse(.tooManyRedirects) }
        if chain.contains(where: { Self.normalised($0) == Self.normalised(to) }) { return .refuse(.redirectLoop) }
        if from.scheme?.lowercased() == "https", scheme == "http" { return .refuse(.insecureRedirect) }
        // A public site may never send a download inside the network (the usual way a download is turned into a request against something private),
        // and an internal one is only for the person's own requests.
        let target = Self.classify(host: host)
        if target.isInternal {
            let fromInternal = Self.classify(host: from.host ?? "").isInternal
            if !allowsInternalHosts || !fromInternal { return .refuse(.redirectIntoInternalNetwork(host)) }
        }
        return .follow(dropCredentials: Self.origin(of: from) != Self.origin(of: to))
    }

    static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "", host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    private static func normalised(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        let scheme = parts.scheme?.lowercased(), host = parts.host?.lowercased()
        parts.scheme = scheme
        parts.host = host
        return parts.url?.absoluteString ?? url.absoluteString
    }

    /// What kind of place a host is, from the name alone (no lookup is made: a name that resolves to a private address is not caught here, see the Phase 2 notes).
    static func classify(host rawHost: String) -> HostClass {
        var host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") && !host.contains(":") { return .localName }
        if let v4 = ipv4(host) { return classify(v4: v4) }
        // Other spellings of an IPv4 address (127.1, 0x7f.0.0.1, 0177.0.0.1) are read as addresses by the system, so they are never treated as public names. No real host name ends in a number.
        if !host.contains(":"), Self.looksNumeric(host) { return .unspecified }
        if host.contains(":") {
            let bytes = ipv6(host)
            guard let b = bytes else { return .publicHost }
            if b.allSatisfy({ $0 == 0 }) { return .unspecified }
            if b.dropLast().allSatisfy({ $0 == 0 }), b.last == 1 { return .loopback }
            if (b[0] & 0xFE) == 0xFC { return .privateNetwork }                       // fc00::/7
            if b[0] == 0xFE, (b[1] & 0xC0) == 0x80 { return .linkLocal }              // fe80::/10
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return classify(v4: [b[12], b[13], b[14], b[15]]) }   // ::ffff:a.b.c.d
            if b[0..<12].allSatisfy({ $0 == 0 }) { return classify(v4: [b[12], b[13], b[14], b[15]]) }                                  // ::a.b.c.d (deprecated)
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B, b[4..<12].allSatisfy({ $0 == 0 }) { return classify(v4: [b[12], b[13], b[14], b[15]]) }   // 64:ff9b::/96 (NAT64)
            if b[0] == 0x20, b[1] == 0x02 { return classify(v4: [b[2], b[3], b[4], b[5]]) }                                              // 2002::/16 (6to4)
            if b[0] == 0xFE, (b[1] & 0xC0) == 0xC0 { return .privateNetwork }                                                             // fec0::/10 (site-local)
            if b[0] == 0xFF { return .unspecified }                                                                                        // multicast
            return .publicHost
        }
        return .publicHost
    }

    private static func looksNumeric(_ host: String) -> Bool {
        if host.hasPrefix("0x") { return true }
        guard let last = host.split(separator: ".").last else { return false }
        return last.allSatisfy { $0.isASCII && $0.isNumber } || last.hasPrefix("0x")
    }

    private static func classify(v4 b: [UInt8]) -> HostClass {
        switch (b[0], b[1]) {
        case (0, _): return .unspecified
        case (127, _): return .loopback
        case (10, _): return .privateNetwork
        case (172, 16...31): return .privateNetwork
        case (192, 168): return .privateNetwork
        case (169, 254): return .linkLocal
        case (100, 64...127): return .privateNetwork       // carrier-grade NAT
        default: return b[0] >= 224 ? .unspecified : .publicHost    // multicast and reserved
        }
    }

    /// Dotted decimal only (a host written as an integer or with octal or hex parts is resolved by the system's own rules, so it is treated as not a literal here and left to
    /// the connection; those spellings are refused outright below, since no honest address needs them).
    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for part in parts { guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), part.count == 1 || part.first != "0", let v = UInt8(part) else { return nil }; out.append(v) }
        return out
    }

    private static func ipv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let withoutZone = host.split(separator: "%").first.map(String.init) ?? host
        guard inet_pton(AF_INET6, withoutZone, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}

/// A signed address (one with a token in its query) must not appear in a log line, a diagnostic or an error message.
enum DownloadURLRedactor {
    /// "https://host/path/file.zip?token=abc&x=1" becomes "https://host/path/file.zip?token=***&x=***". No user name, password or fragment either.
    static func redact(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(no address)" }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if let items = parts.queryItems, !items.isEmpty { parts.queryItems = items.map { URLQueryItem(name: $0.name, value: $0.value == nil ? nil : "***") } }
        return parts.string ?? "(address)"
    }

    static func redact(_ text: String) -> String { redact(URL(string: text)) }

    /// Query names whose values are secrets (a signature, a token, a key): the values of these are what is never written to disk.
    static func isSecretName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("x-amz-") && n != "x-amz-expires" && n != "x-amz-date" && n != "x-amz-algorithm" && n != "x-amz-signedheaders"
            || n.hasPrefix("x-goog-") && n != "x-goog-expires" && n != "x-goog-date" && n != "x-goog-algorithm" && n != "x-goog-signedheaders"
            || ["token", "sig", "signature", "key", "auth", "jwt", "access_token", "credential", "se", "sp", "sv", "skoid", "sktid", "expires"].contains(n)
    }

    /// The form of an address that is written to disk. A signed or token-bearing address (a presigned object link, a SAS, a one-time token) keeps its query names, and the values of the
    /// secret ones are left empty: the secret lives only in memory for as long as the app runs. After a relaunch the empty value says the link lost its secret (`lostSecret`), so it is never
    /// started, retried or resumed from that stump; the person is asked for a fresh link instead.
    static func persistable(_ text: String?) -> String? {
        guard let text, let url = URL(string: text), looksSigned(url) || SignedURL.isSigned(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return text }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        parts.queryItems = parts.queryItems?.map { isSecretName($0.name) && $0.value != nil ? URLQueryItem(name: $0.name, value: "") : $0 }
        return parts.string ?? text
    }

    /// An address that was written by `persistable`: a secret-named query item with nothing in it.
    static func lostSecret(_ url: URL?) -> Bool {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains { isSecretName($0.name) && $0.value == "" }
    }

    /// Whether the address carries something that looks like a credential in its query or path (a token, a signature, a key).
    static func looksSigned(_ url: URL?) -> Bool {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let sensitive = ["token", "sig", "signature", "key", "auth", "expires", "x-amz-signature", "x-goog-signature", "se", "sp", "sv", "jwt", "access_token", "credential", "x-amz-security-token", "x-goog-credential", "x-amz-credential", "skoid", "sktid"]
        return items.contains { sensitive.contains($0.name.lowercased()) }
    }
}
