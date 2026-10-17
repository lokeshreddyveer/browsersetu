import Foundation

/// A proxy the user already has: an address, a port and optionally a login. The browser sends page loads through it; it is not a VPN, and it is
/// never chosen or contacted without the user having entered it.
struct ProxyConfig: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case http, socks5
        var id: String { rawValue }
        var title: String { self == .http ? "HTTP / HTTPS" : "SOCKS5" }
    }

    var kind: Kind = .http
    var host = ""
    var port = 0
    var username = ""

    enum Problem: LocalizedError, Equatable {
        case noHost, badHost, badPort

        var errorDescription: String? {
            switch self {
            case .noHost: "Enter the proxy’s address."
            case .badHost: "Enter only the address, such as proxy.example.com or 192.168.1.5, without http:// or a path."
            case .badPort: "The port is a number from 1 to 65535."
            }
        }
    }

    /// A configuration from what was typed, or the first thing wrong with it.
    static func validated(kind: Kind, host rawHost: String, port rawPort: String, username: String) -> Result<ProxyConfig, Problem> {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failure(.noHost) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }), !host.contains("://") else { return .failure(.badHost) }
        guard let port = Int(rawPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return .failure(.badPort) }
        return .success(ProxyConfig(kind: kind, host: host, port: port, username: username.trimmingCharacters(in: .whitespaces)))
    }

    var summary: String { "\(host):\(port)" }

    static let keychainService = "com.browsersetu.proxy"
    static var password: String? {
        SecretStore.get(service: keychainService, account: "password").flatMap { String(data: $0, encoding: .utf8) }
    }
    static func setPassword(_ text: String) {
        if text.isEmpty { _ = SecretStore.delete(service: keychainService, account: "password") }
        else { _ = SecretStore.set(Data(text.utf8), service: keychainService, account: "password") }
    }
}

/// Whether page loads currently go through a proxy. Things the browser fetches on its own (site icons, blocking-list updates) are not sent through
/// it, so while a proxy is on they stay off or are announced rather than quietly revealing the real address.
@MainActor
enum ProxyState {
    /// Read from any thread (the download code runs off the main actor); only the main actor ever changes it.
    nonisolated(unsafe) static var active = false
}
