import Foundation
#if os(macOS)
import CoreServices
#endif

// Closing the hostname gap of Phase 2. A name that looks public can resolve to a private, loopback or link-local address (or be changed to one between the check and the
// connection: DNS rebinding). What is, and is not, enforced:
//
//   - Before a request, and before following any redirect, a hostname is resolved (IPv4 and IPv6, every address) and refused if any address is internal. Done for every request
//     that is not the person's own, and for every redirect from a public place to a name that resolves into the network.
//   - After the connection, the address the system transfer API actually connected to (the task metrics' remote address) is checked too. That catches a name that resolved differently
//     the second time, including on a reused connection. The check comes after the request, so a single read-only GET may already have reached the internal address: the response
//     is discarded and the file is never finalised. The system gives no hook to refuse a connection before it is made, so this is detection, not prevention, and it is
//     described that way.
//   - Where the address cannot be known (a proxy resolves the name, or the metrics carry no address), a request that is not the person's own is refused rather than assumed safe.
//
// The person's own requests may reach their own network by name (a NAS, a local server); only the redirect rule (a public place cannot send them inside) applies to them.

protocol HostAddressResolving: Sendable {
    /// Every address a host name resolves to, as numeric strings. Nil when it could not be resolved.
    func addresses(for host: String) async -> [String]?
}

struct SystemHostResolver: HostAddressResolving {
    func addresses(for host: String) async -> [String]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { continuation.resume(returning: nil); return }
                defer { freeaddrinfo(result) }
                var out: [String] = []
                var node: UnsafeMutablePointer<addrinfo>? = first
                while let current = node, out.count < 32 {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let text = String(cString: buffer).split(separator: "%").first.map(String.init) ?? ""    // a zone suffix is not part of the address
                        if !text.isEmpty, !out.contains(text) { out.append(text) }
                    }
                    node = current.pointee.ai_next
                }
                continuation.resume(returning: out.isEmpty ? nil : out)
            }
        }
    }
}

extension HTTPRequestPolicy {
    /// What resolves hostnames. Tests replace it; nothing else does.
    nonisolated(unsafe) static var resolver: HostAddressResolving = SystemHostResolver()

    /// The worst thing a host is: its own name or literal address if that says so, otherwise the worst of what it resolves to.
    /// `resolved` is nil for a name that could not be resolved.
    static func classifyResolving(host: String) async -> (kind: HostClass, resolved: [String]?) {
        let byName = classify(host: host)
        if byName != .publicHost { return (byName, nil) }
        if isLiteral(host) { return (.publicHost, [host]) }                 // a public literal address
        guard let addresses = await resolver.addresses(for: host) else { return (.publicHost, nil) }
        let kinds = addresses.map { classify(host: $0) }
        let order: [HostClass] = [.loopback, .privateNetwork, .linkLocal, .unspecified, .localName]
        for kind in order where kinds.contains(kind) { return (kind, addresses) }
        return (.publicHost, addresses)
    }

    private static func isLiteral(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, trimmed, &v4) == 1 || inet_pton(AF_INET6, trimmed.split(separator: "%").first.map(String.init) ?? trimmed, &v6) == 1
    }

    /// The first address of a request: the name rules, and (for anyone but the person) what the name resolves to. Fails closed when that cannot be known.
    func checkResolving(_ url: URL) async throws {
        try requireAllowedOrigin()
        try check(url)
        guard !allowsInternalHosts, let host = url.host else { return }
        let (kind, resolved) = await Self.classifyResolving(host: host)
        if kind.isInternal { throw Refusal.internalAddress(host) }
        if resolved == nil { throw Refusal.unverifiable(host) }
    }

    /// `decideRedirect`, and then what the target resolves to: a public place may never send a download into the network, and an internal one is only for the person's own requests.
    /// `resolve` is how a name is looked up (the real resolver unless a test says otherwise).
    func decideRedirectResolving(from: URL, to: URL, chain: [URL], resolve: (String) async -> (kind: HostClass, resolved: [String]?) = { await HTTPRequestPolicy.classifyResolving(host: $0) }) async -> RedirectDecision {
        let decision = decideRedirect(from: from, to: to, chain: chain)
        guard case .follow = decision, let host = to.host else { return decision }
        let target = await resolve(host)
        if target.kind.isInternal {
            let origin = await resolve(from.host ?? "")
            if !allowsInternalHosts || !origin.kind.isInternal { return .refuse(.redirectIntoInternalNetwork(host)) }
        } else if target.resolved == nil, !allowsInternalHosts {
            return .refuse(.unverifiable(host))
        }
        return decision
    }

    enum ConnectionVerdict: Equatable, Sendable {
        case acceptable
        case refuse(Refusal)
    }

    /// After the connection: was the address it really went to one this request may reach? `remote` is the numeric address from the transaction metrics (nil when the system gave none),
    /// `viaProxy` that the connection was to a proxy (so `remote` is the proxy, not the site), `fromPublic` that the request began at a public place.
    func verifyConnection(host: String, remote: String?, viaProxy: Bool, fromPublic: Bool) -> ConnectionVerdict {
        if allowsInternalHosts && !fromPublic { return .acceptable }
        if viaProxy { return allowsInternalHosts ? .acceptable : .refuse(.unverifiable(host)) }
        guard let remote, !remote.isEmpty else { return allowsInternalHosts ? .acceptable : .refuse(.unverifiable(host)) }
        let kind = Self.classify(host: remote.split(separator: "%").first.map(String.init) ?? remote)
        if kind.isInternal { return .refuse(.connectedToInternalAddress(host, remote)) }
        return .acceptable
    }
}

/// Marks a finished file as downloaded from the internet, as the system does for a browser's own downloads, so Gatekeeper treats it accordingly. Only the origin of the address is
/// recorded, never the full address (which may carry a token).
enum DownloadQuarantine {
    static func apply(to file: URL, sourceOrigin: String) {
        #if os(macOS)
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String, kLSQuarantineAgentNameKey as String: "Browser Setu",
                                       kLSQuarantineDataURLKey as String: sourceOrigin]
        var mutable = file
        try? mutable.setResourceValues(values)
        #endif
    }

    static func isQuarantined(_ file: URL) -> Bool {
        #if os(macOS)
        return getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
        #else
        return false
        #endif
    }
}
