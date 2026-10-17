import Foundation

/// A local list of hosts the user has chosen to treat as deceptive (phishing or malware). Nothing is bundled or
/// downloaded: the list comes from a file the user imports, so what it contains and where it came from is their
/// call, and no visited address ever leaves the device.
struct ThreatList: Equatable {
    private(set) var hosts: Set<String>

    static let empty = ThreatList(hosts: [])
    static let maxBytes = 20 * 1024 * 1024
    static let maxHosts = 2_000_000

    init(hosts: Set<String>) { self.hosts = hosts }

    var count: Int { hosts.count }
    var isEmpty: Bool { hosts.isEmpty }

    /// Accepts one host per line, hosts-file lines (`0.0.0.0 example.com`), ad-block style `||example.com^`, or full
    /// URLs. Comments and anything that is not a plausible host name are skipped.
    static func parse(_ text: String) -> ThreatList {
        var found = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            if found.count >= maxHosts { break }
            var entry = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            entry = entry.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            var tokens = entry.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let first = tokens.first, isAddress(first), tokens.count > 1 { tokens.removeFirst() }
            guard var token = tokens.first else { continue }
            if token.contains("://"), let host = URL(string: token)?.host { token = host }
            if token.hasPrefix("||") { token.removeFirst(2) }
            if token.hasPrefix("*.") { token.removeFirst(2) }
            if let caret = token.firstIndex(of: "^") { token = String(token[..<caret]) }
            if let slash = token.firstIndex(of: "/") { token = String(token[..<slash]) }
            token = token.lowercased()
            if token.hasSuffix(".") { token.removeLast() }
            if isPlausibleHost(token) { found.insert(token) }
        }
        return ThreatList(hosts: found)
    }

    /// True for the host itself and for any subdomain of a listed host.
    func contains(host: String) -> Bool {
        var candidate = host.lowercased()
        if candidate.hasSuffix(".") { candidate.removeLast() }
        guard !hosts.isEmpty else { return false }
        while true {
            if hosts.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = String(candidate[candidate.index(after: dot)...])
            if !candidate.contains(".") { return false }   // never match a bare top-level domain
        }
    }

    private static func isAddress(_ token: String) -> Bool {
        token == "0.0.0.0" || token == "127.0.0.1" || token == "::1" || token == "::"
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard host.count >= 4, host.count <= 253, host.contains("."), !host.contains("..") else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        if host.first == "-" || host.first == "." { return false }
        return host.unicodeScalars.allSatisfy { s in
            (s.value >= 0x61 && s.value <= 0x7a) || (s.value >= 0x30 && s.value <= 0x39) || s == "-" || s == "." || s == "_"
        }
    }
}

/// Keeps the imported list in the app's own folder.
enum ThreatListStore {
    static func url(root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent("threat-hosts.txt") }

    static func load(root: String) -> ThreatList {
        guard let data = try? Data(contentsOf: url(root: root)), data.count <= ThreatList.maxBytes,
              let text = String(data: data, encoding: .utf8) else { return .empty }
        return ThreatList.parse(text)
    }

    /// Replaces the stored list. Throws when the file is too large or not text.
    @discardableResult
    static func save(_ data: Data, root: String) throws -> ThreatList {
        guard data.count <= ThreatList.maxBytes else { throw ThreatListError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ThreatListError.notText }
        let list = ThreatList.parse(text)
        guard !list.isEmpty else { throw ThreatListError.noHosts }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try data.write(to: url(root: root), options: .atomic)
        return list
    }

    static func remove(root: String) { try? FileManager.default.removeItem(at: url(root: root)) }
}

enum ThreatListError: LocalizedError {
    case tooLarge, notText, noHosts
    var errorDescription: String? {
        switch self {
        case .tooLarge: "That file is larger than 20 MB."
        case .notText: "That file is not a text list."
        case .noHosts: "No host names were found in that file."
        }
    }
}
